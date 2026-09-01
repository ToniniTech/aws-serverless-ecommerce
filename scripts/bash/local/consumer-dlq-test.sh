#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

source_queue="$(get_terraform_output notification_order_created_queue_url)"
dead_letter_queue="$(get_terraform_output notification_order_created_dlq_url)"
max_receive_count="$(get_terraform_output max_receive_count)"
original_visibility="$(invoke_local_aws sqs get-queue-attributes \
    --queue-url "$source_queue" \
    --attribute-names VisibilityTimeout \
    --query Attributes.VisibilityTimeout \
    --output text)"

restore_visibility() {
    invoke_local_aws sqs set-queue-attributes \
        --queue-url "$source_queue" \
        --attributes "VisibilityTimeout=$original_visibility" >/dev/null
}
trap restore_visibility EXIT

clear_local_queue "$source_queue"
clear_local_queue "$dead_letter_queue"

event_id="$(new_uuid)"
order_id="order-dlq-$(new_uuid)"
message_body="$(jq -c \
    --arg eventId "$event_id" \
    --arg orderId "$order_id" \
    --arg correlationId "correlation-$event_id" \
    --arg occurredAt "$(utc_timestamp)" \
    '.eventId = $eventId
     | .orderId = $orderId
     | .correlationId = $correlationId
     | .occurredAt = $occurredAt' \
    "$REPOSITORY_ROOT/examples/order-created.json")"
failure_attribute='{"forceFailure":{"DataType":"String","StringValue":"true"}}'

invoke_local_aws sqs set-queue-attributes \
    --queue-url "$source_queue" \
    --attributes VisibilityTimeout=2 >/dev/null

invoke_local_aws_with_json_input --message-body "$message_body" \
    sqs send-message \
    --queue-url "$source_queue" \
    --message-attributes "$failure_attribute" >/dev/null

deadline=$(( $(epoch_seconds) + 60 ))
dead_letter=""
while (( $(epoch_seconds) < deadline )); do
    dead_letter="$(receive_local_message "$dead_letter_queue" 5 1)"
    [[ -n "$dead_letter" ]] && break
    sleep 1
done

[[ -n "$dead_letter" && "$(jq -r '.Body' <<<"$dead_letter")" == *"$event_id"* ]] ||
    die "Notification failure did not reach its DLQ after $max_receive_count receives."

notification_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notifications WHERE event_id = '$event_id';")"
processed_count="$(invoke_local_postgres_scalar \
    "SELECT count(*) FROM notification_domain.notification_processed_events WHERE event_id = '$event_id';")"
[[ "$notification_count" == "0" && "$processed_count" == "0" ]] ||
    die "The intentionally failed event crossed the Notification transaction boundary."

remove_local_message "$dead_letter_queue" "$(jq -r '.ReceiptHandle' <<<"$dead_letter")"
printf 'Z4 Lambda retry and DLQ test passed.\n'
printf 'Event ID: %s\n' "$event_id"
printf 'SQS redrove the failed record after maxReceiveCount=%s.\n' "$max_receive_count"
printf 'Notification and ProcessedEvent rows: 0\n'

