#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

start_saga_execution() {
    local state_machine_arn="$1"
    local payload="$2"
    local name="saga-$(new_uuid_compact)"
    local started

    started="$(invoke_local_aws_with_json_input --input "$payload" \
        stepfunctions start-execution \
        --state-machine-arn "$state_machine_arn" \
        --name "$name")"
    jq -r '.executionArn' <<<"$started"
}

wait_saga_execution() {
    local execution_arn="$1"
    local deadline=$(( $(epoch_seconds) + 180 ))
    local execution
    local status

    while (( $(epoch_seconds) < deadline )); do
        execution="$(invoke_local_aws stepfunctions describe-execution \
            --execution-arn "$execution_arn")"
        status="$(jq -r '.status' <<<"$execution")"
        case "$status" in
            SUCCEEDED|FAILED|TIMED_OUT|ABORTED)
                printf '%s\n' "$execution"
                return
                ;;
        esac
        sleep 2
    done

    die "Timed out waiting for Saga execution $execution_arn."
}

state_machine_arn="$(get_terraform_output order_saga_state_machine_arn)"

success_saga_id="saga-success-$(new_uuid)"
success_order_id="saga-order-success-$(new_uuid)"
success_input="$(jq -cn \
    --arg sagaId "$success_saga_id" \
    --arg orderId "$success_order_id" \
    '{
        sagaId: $sagaId,
        orderId: $orderId,
        productId: "prod-001",
        quantity: 1,
        amount: 129.99,
        currency: "USD"
    }')"
success_arn="$(start_saga_execution "$state_machine_arn" "$success_input")"
success="$(wait_saga_execution "$success_arn")"
success_status="$(jq -r '.status' <<<"$success")"
[[ "$success_status" == "SUCCEEDED" ]] ||
    die "Successful Saga execution ended as $success_status: $(jq -r '.cause // empty' <<<"$success")"
[[ "$(jq -r '.output | fromjson | .confirmation.value.orderStatus' <<<"$success")" == "CONFIRMED" ]] ||
    die "Successful Saga did not confirm the Order."

keyboard_after_first_execution="$(invoke_local_postgres_scalar \
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-001';")"

duplicate_success_arn="$(start_saga_execution "$state_machine_arn" "$success_input")"
duplicate_success="$(wait_saga_execution "$duplicate_success_arn")"
duplicate_success_status="$(jq -r '.status' <<<"$duplicate_success")"
[[ "$duplicate_success_status" == "SUCCEEDED" ]] ||
    die "Duplicate successful Saga ended as $duplicate_success_status: $(jq -r '.cause // empty' <<<"$duplicate_success")"
keyboard_after_duplicate="$(invoke_local_postgres_scalar \
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-001';")"
[[ "$keyboard_after_duplicate" == "$keyboard_after_first_execution" ]] ||
    die "Duplicate successful Saga decremented stock more than once."

success_reservation_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM saga_demo.saga_stock_reservations WHERE saga_id = '$success_saga_id' AND quantity = 1 AND status = 'RESERVED';")"
[[ "$success_reservation_count" == "1" ]] ||
    die "Successful Saga did not persist exactly one active stock reservation."

failed_saga_id="saga-failed-$(new_uuid)"
failed_order_id="saga-order-failed-$(new_uuid)"
mouse_before="$(invoke_local_postgres_scalar \
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")"
failed_input="$(jq -cn \
    --arg sagaId "$failed_saga_id" \
    --arg orderId "$failed_order_id" \
    '{
        sagaId: $sagaId,
        orderId: $orderId,
        productId: "prod-002",
        quantity: 1,
        amount: 100.13,
        currency: "USD"
    }')"
failed_arn="$(start_saga_execution "$state_machine_arn" "$failed_input")"
failed="$(wait_saga_execution "$failed_arn")"
failed_status="$(jq -r '.status' <<<"$failed")"
[[ "$failed_status" == "SUCCEEDED" ]] ||
    die "Compensated Saga execution ended as $failed_status: $(jq -r '.cause // empty' <<<"$failed")"
failure_code="$(jq -r '.output | fromjson | .payment.value.failureCode' <<<"$failed")"
reservation_status="$(jq -r '.output | fromjson | .compensation.value.reservationStatus' <<<"$failed")"
[[ "$failure_code" == "CARD_EXPIRED" && "$reservation_status" == "COMPENSATED" ]] ||
    die "Failed Payment did not execute the expected stock compensation."

mouse_after="$(invoke_local_postgres_scalar \
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")"
[[ "$mouse_after" == "$mouse_before" ]] || die "Compensated Saga did not restore stock."

duplicate_failed_arn="$(start_saga_execution "$state_machine_arn" "$failed_input")"
duplicate_failed="$(wait_saga_execution "$duplicate_failed_arn")"
duplicate_failed_status="$(jq -r '.status' <<<"$duplicate_failed")"
[[ "$duplicate_failed_status" == "SUCCEEDED" ]] ||
    die "Duplicate compensated Saga ended as $duplicate_failed_status: $(jq -r '.cause // empty' <<<"$duplicate_failed")"
mouse_after_duplicate="$(invoke_local_postgres_scalar \
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")"
[[ "$mouse_after_duplicate" == "$mouse_before" ]] || die "Duplicate compensated Saga changed stock."

failed_order_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM saga_demo.saga_orders WHERE saga_id = '$failed_saga_id';")"
[[ "$failed_order_count" == "0" ]] || die "Compensated Saga created a confirmed Order."

printf 'Z5 local Step Functions Saga passed.\n'
printf 'Success: Order CONFIRMED; duplicate execution kept stock at %s.\n' "$keyboard_after_duplicate"
printf 'Payment failure: stock %s -> %s, reservation COMPENSATED; duplicate was harmless.\n' \
    "$mouse_before" "$mouse_after_duplicate"
printf 'State machine: %s\n' "$state_machine_arn"

