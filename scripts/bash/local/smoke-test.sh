#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

topic_arn="$(get_terraform_output order_events_topic_arn)"
event_bus="$(get_terraform_output payment_events_bus_name)"
payment_queue="$(get_terraform_output payment_order_created_queue_url)"
order_notification_queue="$(get_terraform_output notification_order_created_queue_url)"
order_result_queue="$(get_terraform_output order_payment_result_queue_url)"
result_notification_queue="$(get_terraform_output notification_payment_result_queue_url)"

suspended_mappings=()
mapfile -t suspended_mappings < <(suspend_local_event_source_mappings)
cleanup() {
    resume_local_event_source_mappings "${suspended_mappings[@]}"
}
trap cleanup EXIT

queues=(
    "$payment_queue"
    "$order_notification_queue"
    "$order_result_queue"
    "$result_notification_queue"
)
for queue in "${queues[@]}"; do
    clear_local_queue "$queue"
done

order_event_id="$(new_uuid)"
correlation_id="$(new_uuid)"
order_id="$(new_uuid)"
order_created="$(jq -cn \
    --arg eventId "$order_event_id" \
    --arg occurredAt "$(utc_timestamp)" \
    --arg correlationId "$correlation_id" \
    --arg orderId "$order_id" \
    '{
        eventId: $eventId,
        eventType: "OrderCreated",
        occurredAt: $occurredAt,
        correlationId: $correlationId,
        orderId: $orderId,
        customerId: "local-customer-001",
        totalAmount: 19990,
        currency: "CLP",
        items: [{productId: "prod-001", quantity: 1, unitPrice: 19990}]
    }')"

invoke_local_aws sns publish \
    --topic-arn "$topic_arn" \
    --message "$order_created" >/dev/null

for queue in "$payment_queue" "$order_notification_queue"; do
    message="$(receive_local_message "$queue")"
    [[ -n "$message" && "$(jq -r '.Body' <<<"$message")" == *"$order_event_id"* ]] ||
        die "SNS fan-out verification failed for $queue."
    remove_local_message "$queue" "$(jq -r '.ReceiptHandle' <<<"$message")"
done

payment_event_id="$(new_uuid)"
payment_detail="$(jq -cn \
    --arg eventId "$payment_event_id" \
    --arg occurredAt "$(utc_timestamp)" \
    --arg correlationId "$correlation_id" \
    --arg orderId "$order_id" \
    --arg paymentId "$(new_uuid)" \
    '{
        eventId: $eventId,
        eventType: "PaymentProcessed",
        occurredAt: $occurredAt,
        correlationId: $correlationId,
        orderId: $orderId,
        paymentId: $paymentId,
        amount: 19990,
        currency: "CLP"
    }')"
entries="$(jq -cn \
    --arg detail "$payment_detail" \
    --arg eventBus "$event_bus" \
    '[{
        Source: "com.ecommerce.payment",
        DetailType: "PaymentProcessed",
        Detail: $detail,
        EventBusName: $eventBus
    }]')"

invoke_local_aws_with_json_input --entries "$entries" events put-events >/dev/null

for queue in "$order_result_queue" "$result_notification_queue"; do
    message="$(receive_local_message "$queue")"
    [[ -n "$message" && "$(jq -r '.Body' <<<"$message")" == *"$payment_event_id"* ]] ||
        die "EventBridge routing verification failed for $queue."
    remove_local_message "$queue" "$(jq -r '.ReceiptHandle' <<<"$message")"
done

printf 'Z1 smoke test passed.\n'
printf 'SNS delivered one OrderCreated event to both independent SQS queues.\n'
printf 'EventBridge delivered one PaymentProcessed event to both independent SQS queues.\n'

