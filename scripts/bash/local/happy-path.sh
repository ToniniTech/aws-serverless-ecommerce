#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

order_command_function="$(get_terraform_output order_command_function_name)"
order_query_function="$(get_terraform_output order_query_function_name)"
order_outbox_function="$(get_terraform_output order_outbox_function_name)"
payment_outbox_function="$(get_terraform_output payment_outbox_function_name)"
notification_function="$(get_terraform_output notification_function_name)"

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

correlation_id="local-$(new_uuid)"
idempotency_key="local-request-$(new_uuid)"
request_body='{"items":[{"productId":"prod-001","quantity":1}]}'
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
            "x-customer-id": "local-customer-001",
            "x-customer-email": "local.customer@example.test",
            "x-correlation-id": $correlationId,
            "idempotency-key": $idempotencyKey
        },
        body: $body,
        isBase64Encoded: false
    }')"

create_payload="$(invoke_local_lambda "$order_command_function" "$create_event")"
create_status="$(jq -r '.statusCode' <<<"$create_payload")"
[[ "$create_status" == "201" ]] ||
    die "Order Command returned $create_status: $(jq -r '.body' <<<"$create_payload")"
order_id="$(jq -r '.body | fromjson | .orderId' <<<"$create_payload")"

order_outbox_payload="$(invoke_local_lambda "$order_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$order_outbox_payload") >= 1 )) ||
    die "Order Outbox did not publish the OrderCreated event: $order_outbox_payload"

payment_deadline=$(( $(epoch_seconds) + 90 ))
payment_outbox_count=0
while (( $(epoch_seconds) < payment_deadline )); do
    payment_outbox_count="$(invoke_local_postgres_scalar \
        "SELECT count(*) FROM payment_outbox WHERE aggregate_id = '$order_id';")"
    (( payment_outbox_count > 0 )) && break
    sleep 2
done
(( payment_outbox_count > 0 )) ||
    die "Payment Lambda did not persist a Payment Outbox event for Order $order_id."

payment_outbox_payload="$(invoke_local_lambda "$payment_outbox_function" '{}')"
(( $(jq -r '.published' <<<"$payment_outbox_payload") >= 1 )) ||
    die "Payment Outbox did not publish a payment result: $payment_outbox_payload"

order_deadline=$(( $(epoch_seconds) + 90 ))
status=PENDING
while (( $(epoch_seconds) < order_deadline )); do
    status="$(invoke_local_postgres_scalar \
        "SELECT status FROM order_domain.orders WHERE order_id = '$order_id';")"
    [[ "$status" == "PAID" || "$status" == "FAILED" ]] && break
    sleep 2
done
[[ "$status" == "PAID" ]] || die "Expected Order $order_id to become PAID, but its status is $status."

query_event="$(jq -cn \
    --arg orderId "$order_id" \
    '{
        version: "2.0",
        routeKey: "GET /orders/{orderId}",
        rawPath: ("/orders/" + $orderId),
        pathParameters: {orderId: $orderId}
    }')"
query_payload="$(invoke_local_lambda "$order_query_function" "$query_event")"
query_status="$(jq -r '.statusCode' <<<"$query_payload")"
order_view_status="$(jq -r '.body | fromjson | .status' <<<"$query_payload")"
[[ "$query_status" == "200" && "$order_view_status" == "PAID" ]] ||
    die "Order Query did not return the expected PAID projection: $query_payload"

notification_deadline=$(( $(epoch_seconds) + 90 ))
notification_count=0
while (( $(epoch_seconds) < notification_deadline )); do
    notification_schema_ready="$(invoke_local_postgres_scalar \
        "SELECT CASE WHEN to_regclass('notification_domain.notifications') IS NULL THEN 0 ELSE 1 END;")"
    if [[ "$notification_schema_ready" == "1" ]]; then
        notification_count="$(invoke_local_postgres_scalar \
            "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$order_id';")"
    fi
    [[ "$notification_count" == "2" ]] && break
    sleep 2
done
[[ "$notification_count" == "2" ]] ||
    die "Expected two Notification records for Order $order_id, but found $notification_count."

order_created_payload="$(invoke_local_postgres_scalar \
    "SELECT payload::text FROM order_domain.order_outbox WHERE aggregate_id = '$order_id' AND event_type = 'OrderCreated' LIMIT 1;")"
duplicate_notification_event="$(jq -cn \
    --arg messageId "duplicate-$(new_uuid)" \
    --arg body "$order_created_payload" \
    '{
        Records: [{
            messageId: $messageId,
            body: $body,
            attributes: {ApproximateReceiveCount: "2"},
            messageAttributes: {}
        }]
    }')"
duplicate_payload="$(invoke_local_lambda "$notification_function" "$duplicate_notification_event")"
[[ "$(jq -r '.batchItemFailures | length' <<<"$duplicate_payload")" == "0" ]] ||
    die "Notification duplicate was returned as a batch failure: $duplicate_payload"

notification_count_after_duplicate="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$order_id';")"
[[ "$notification_count_after_duplicate" == "2" ]] ||
    die "Notification duplicate created an extra row for Order $order_id."

payment_status="$(invoke_local_postgres_scalar "SELECT status FROM payments WHERE order_id = '$order_id';")"
processed_payment_events="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM processed_events WHERE order_id = '$order_id';")"
processed_order_events="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM order_domain.order_processed_events WHERE order_id = '$order_id';")"
processed_notification_events="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notification_processed_events WHERE order_id = '$order_id';")"

printf 'Z3 happy path and Notification duplicate replay passed.\n'
printf 'Order ID: %s\n' "$order_id"
printf 'Payment status: %s\n' "$payment_status"
printf 'Order status: %s\n' "$order_view_status"
printf 'Payment processed-event rows: %s\n' "$processed_payment_events"
printf 'Order processed-event rows: %s\n' "$processed_order_events"
printf 'Notification rows: %s\n' "$notification_count_after_duplicate"
printf 'Notification processed-event rows: %s\n' "$processed_notification_events"

