#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

order_command_function="$(get_terraform_output order_command_function_name)"
order_query_function="$(get_terraform_output order_query_function_name)"
order_outbox_function="$(get_terraform_output order_outbox_function_name)"
payment_outbox_function="$(get_terraform_output payment_outbox_function_name)"
payment_event_bus="$(get_terraform_output payment_events_bus_name)"

queues_to_clear=(
    "$(get_terraform_output payment_order_created_queue_url)"
    "$(get_terraform_output payment_order_created_dlq_url)"
    "$(get_terraform_output notification_order_created_queue_url)"
    "$(get_terraform_output notification_order_created_dlq_url)"
    "$(get_terraform_output order_payment_result_queue_url)"
    "$(get_terraform_output order_payment_result_dlq_url)"
    "$(get_terraform_output notification_payment_result_queue_url)"
    "$(get_terraform_output notification_payment_result_dlq_url)"
)
for queue in "${queues_to_clear[@]}"; do
    clear_local_queue "$queue"
done

correlation_id="local-failure-$(new_uuid)"
idempotency_key="local-failure-request-$(new_uuid)"
request_body='{"items":[{"productId":"prod-001","quantity":8}]}'
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
            "x-customer-id": "local-failure-customer",
            "x-customer-email": "failure.customer@example.test",
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

order_outbox_result="$(invoke_local_lambda "$order_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$order_outbox_result") >= 1 )) ||
    die "Order Outbox did not publish OrderCreated for $order_id."

payment_deadline=$(( $(epoch_seconds) + 90 ))
payment_outbox_count=0
while (( $(epoch_seconds) < payment_deadline )); do
    payment_outbox_count="$(invoke_local_postgres_scalar \
        "SELECT count(*) FROM payment_outbox WHERE aggregate_id = '$order_id';")"
    [[ "$payment_outbox_count" == "1" ]] && break
    sleep 2
done
[[ "$payment_outbox_count" == "1" ]] ||
    die "Payment did not persist exactly one Outbox event for $order_id."

payment_status="$(invoke_local_postgres_scalar "SELECT status FROM payments WHERE order_id = '$order_id';")"
payment_failure_code="$(invoke_local_postgres_scalar \
    "SELECT failure_code FROM payments WHERE order_id = '$order_id';")"
[[ "$payment_status" == "FAILED" && "$payment_failure_code" == "AMOUNT_EXCEEDS_LIMIT" ]] ||
    die "Expected deterministic Payment failure, got $payment_status / $payment_failure_code."

payment_outbox_result="$(invoke_local_lambda "$payment_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$payment_outbox_result") >= 1 )) ||
    die "Payment Outbox did not publish PaymentFailed for $order_id."

result_deadline=$(( $(epoch_seconds) + 90 ))
order_status=""
notification_count=0
while (( $(epoch_seconds) < result_deadline )); do
    order_status="$(invoke_local_postgres_scalar \
        "SELECT status FROM order_domain.orders WHERE order_id = '$order_id';")"
    notification_count="$(invoke_local_postgres_scalar \
        "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$order_id';")"
    [[ "$order_status" == "FAILED" && "$notification_count" == "2" ]] && break
    sleep 2
done
[[ "$order_status" == "FAILED" && "$notification_count" == "2" ]] ||
    die "Failure path did not converge: order=$order_status notifications=$notification_count."

order_failure_code="$(invoke_local_postgres_scalar \
    "SELECT payment_failure_code FROM order_domain.orders WHERE order_id = '$order_id';")"
notification_templates="$(invoke_local_postgres_scalar \
    "SELECT string_agg(template_key, ',' ORDER BY template_key) FROM notification_domain.notifications WHERE order_id = '$order_id';")"
[[ "$order_failure_code" == "AMOUNT_EXCEEDS_LIMIT" ]] || die "Order did not retain the Payment failure code."
[[ "$notification_templates" == "ORDER_CREATED,PAYMENT_FAILED" ]] ||
    die "Unexpected Notification templates: $notification_templates"

payment_event_type="$(invoke_local_postgres_scalar \
    "SELECT event_type FROM payment_outbox WHERE aggregate_id = '$order_id';")"
payment_event_detail="$(invoke_local_postgres_scalar \
    "SELECT payload::text FROM payment_outbox WHERE aggregate_id = '$order_id';")"
duplicate_entry="$(jq -cn \
    --arg detailType "$payment_event_type" \
    --arg detail "$payment_event_detail" \
    --arg eventBus "$payment_event_bus" \
    '[{
        Source: "com.ecommerce.payment",
        DetailType: $detailType,
        Detail: $detail,
        EventBusName: $eventBus
    }]')"
duplicate_publish="$(invoke_local_aws_with_json_input --entries "$duplicate_entry" events put-events)"
[[ "$(jq -r '.FailedEntryCount' <<<"$duplicate_publish")" == "0" ]] ||
    die "EventBridge rejected the duplicate Payment result."

# EventBridge target delivery is asynchronous even in the emulator. Give both warm consumers time
# to handle the deliberate replay before asserting that no durable effect was repeated.
sleep 5
order_version="$(invoke_local_postgres_scalar \
    "SELECT version FROM order_domain.orders WHERE order_id = '$order_id';")"
order_processed_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM order_domain.order_processed_events WHERE order_id = '$order_id';")"
notification_count_after_replay="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$order_id';")"
notification_processed_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notification_processed_events WHERE order_id = '$order_id';")"
[[ "$order_version" == "1" && "$order_processed_count" == "1" ]] ||
    die "Duplicate PaymentFailed repeated the Order effect."
[[ "$notification_count_after_replay" == "2" && "$notification_processed_count" == "2" ]] ||
    die "Duplicate PaymentFailed repeated the Notification effect."

query_event="$(jq -cn \
    --arg orderId "$order_id" \
    '{
        version: "2.0",
        routeKey: "GET /orders/{orderId}",
        rawPath: ("/orders/" + $orderId),
        pathParameters: {orderId: $orderId}
    }')"
query_response="$(invoke_local_lambda "$order_query_function" "$query_event")"
query_status="$(jq -r '.statusCode' <<<"$query_response")"
order_view_status="$(jq -r '.body | fromjson | .status' <<<"$query_response")"
[[ "$query_status" == "200" && "$order_view_status" == "FAILED" ]] ||
    die "Order Query did not expose the final FAILED state."

printf 'Z4 failure path and duplicate PaymentFailed replay passed.\n'
printf 'Order ID: %s\n' "$order_id"
printf 'Payment: %s / %s\n' "$payment_status" "$payment_failure_code"
printf 'Order: %s / %s / version %s\n' "$order_view_status" "$order_failure_code" "$order_version"
printf 'Notifications: %s (%s)\n' "$notification_count_after_replay" "$notification_templates"

