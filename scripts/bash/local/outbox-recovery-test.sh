#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

wait_local_lambda_ready() {
    local function_name="$1"
    local deadline=$(( $(epoch_seconds) + 60 ))
    local configuration
    local state
    local update_status

    while (( $(epoch_seconds) < deadline )); do
        configuration="$(invoke_local_aws lambda get-function-configuration \
            --function-name "$function_name" \
            --query '{State:State,LastUpdateStatus:LastUpdateStatus}' \
            --output json)"
        state="$(jq -r '.State // empty' <<<"$configuration")"
        update_status="$(jq -r '.LastUpdateStatus // empty' <<<"$configuration")"

        if [[ "$state" == "Active" && ( -z "$update_status" || "$update_status" == "Successful" ) ]]; then
            return
        fi
        [[ "$update_status" != "Failed" ]] || die "Local Lambda configuration update failed for $function_name."
        sleep 1
    done

    die "Timed out waiting for local Lambda $function_name to become ready."
}

set_local_lambda_environment() {
    local function_name="$1"
    local variables_json="$2"
    local environment

    environment="$(jq -cn --argjson variables "$variables_json" '{Variables: $variables}')"
    invoke_local_aws_with_json_input --environment "$environment" \
        lambda update-function-configuration \
        --function-name "$function_name" >/dev/null
    wait_local_lambda_ready "$function_name"
}

order_command_function="$(get_terraform_output order_command_function_name)"
order_outbox_function="$(get_terraform_output order_outbox_function_name)"
payment_outbox_function="$(get_terraform_output payment_outbox_function_name)"

outstanding_before="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM order_domain.order_outbox WHERE status <> 'PUBLISHED';")"
[[ "$outstanding_before" == "0" ]] ||
    die "Outbox recovery test requires no pre-existing outstanding Order Outbox rows."

original_variables="$(invoke_local_aws lambda get-function-configuration \
    --function-name "$order_outbox_function" \
    --query Environment.Variables \
    --output json)"
missing_topic="arn:aws:sns:us-east-1:000000000000:missing-z4-$(new_uuid)"
failing_variables="$(jq -c --arg topicArn "$missing_topic" \
    '.ORDER_EVENTS_TOPIC_ARN = $topicArn' <<<"$original_variables")"

environment_changed=false
restore_environment() {
    if [[ "$environment_changed" == true ]]; then
        set_local_lambda_environment "$order_outbox_function" "$original_variables"
    fi
}
trap restore_environment EXIT

correlation_id="local-outbox-recovery-$(new_uuid)"
idempotency_key="local-outbox-recovery-request-$(new_uuid)"
request_body='{"items":[{"productId":"prod-002","quantity":1}]}'
create_event="$(jq -cn \
    --arg body "$request_body" \
    --arg correlationId "$correlation_id" \
    --arg idempotencyKey "$idempotency_key" \
    '{
        version: "2.0",
        routeKey: "POST /orders",
        rawPath: "/orders",
        headers: {
            "content-type": "application/json",
            "x-customer-id": "local-outbox-customer",
            "x-customer-email": "outbox.customer@example.test",
            "x-correlation-id": $correlationId,
            "idempotency-key": $idempotencyKey
        },
        body: $body,
        isBase64Encoded: false
    }')"

create_response="$(invoke_local_lambda "$order_command_function" "$create_event")"
create_status="$(jq -r '.statusCode' <<<"$create_response")"
[[ "$create_status" == "201" ]] ||
    die "Order Command returned $create_status: $(jq -r '.body' <<<"$create_response")"
order_id="$(jq -r '.body | fromjson | .orderId' <<<"$create_response")"

environment_changed=true
set_local_lambda_environment "$order_outbox_function" "$failing_variables"
if invoke_local_lambda "$order_outbox_function" '{}' >/dev/null; then
    die "Order Outbox unexpectedly published to a nonexistent SNS topic."
fi

failed_state="$(invoke_local_postgres_scalar \
    "SELECT status || '|' || attempt_count || '|' || (last_error IS NOT NULL) FROM order_domain.order_outbox WHERE aggregate_id = '$order_id';")"
[[ "$failed_state" == "PENDING|1|true" ]] ||
    die "Order Outbox was not safely released after publication failure: $failed_state"

set_local_lambda_environment "$order_outbox_function" "$original_variables"
environment_changed=false
trap - EXIT

# The first backoff is one second. Restoring the Lambda configuration normally exceeds it, but this
# loop makes the assertion independent of local machine speed.
retry_deadline=$(( $(epoch_seconds) + 15 ))
ready_to_retry=false
while (( $(epoch_seconds) < retry_deadline )); do
    ready_to_retry="$(invoke_local_postgres_scalar \
        "SELECT (next_attempt_at <= CURRENT_TIMESTAMP)::text FROM order_domain.order_outbox WHERE aggregate_id = '$order_id';")"
    [[ "$ready_to_retry" == "true" ]] && break
    sleep 0.5
done
[[ "$ready_to_retry" == "true" ]] || die "Order Outbox row did not become eligible for retry."

recovered_result="$(invoke_local_lambda "$order_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$recovered_result") >= 1 )) ||
    die "Order Outbox did not publish after SNS recovery."
recovered_state="$(invoke_local_postgres_scalar \
    "SELECT status || '|' || attempt_count FROM order_domain.order_outbox WHERE aggregate_id = '$order_id';")"
[[ "$recovered_state" == "PUBLISHED|2" ]] ||
    die "Unexpected recovered Order Outbox state: $recovered_state"

payment_deadline=$(( $(epoch_seconds) + 90 ))
payment_outbox_count=0
while (( $(epoch_seconds) < payment_deadline )); do
    payment_outbox_count="$(invoke_local_postgres_scalar \
        "SELECT count(*) FROM payment_outbox WHERE aggregate_id = '$order_id';")"
    [[ "$payment_outbox_count" == "1" ]] && break
    sleep 2
done
[[ "$payment_outbox_count" == "1" ]] || die "Recovered Order event did not reach Payment."

payment_publish="$(invoke_local_lambda "$payment_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$payment_publish") >= 1 )) ||
    die "Payment Outbox did not finish the recovery scenario."

order_deadline=$(( $(epoch_seconds) + 90 ))
order_status=""
while (( $(epoch_seconds) < order_deadline )); do
    order_status="$(invoke_local_postgres_scalar \
        "SELECT status FROM order_domain.orders WHERE order_id = '$order_id';")"
    [[ "$order_status" == "PAID" ]] && break
    sleep 2
done
[[ "$order_status" == "PAID" ]] || die "Recovered event did not complete the Order flow."

printf 'Z4 Order Outbox recovery test passed.\n'
printf 'Order ID: %s\n' "$order_id"
printf 'Failed publication state: PENDING / attempt 1\n'
printf 'Recovered publication state: PUBLISHED / attempt 2\n'
printf 'Final Order status: %s\n' "$order_status"

