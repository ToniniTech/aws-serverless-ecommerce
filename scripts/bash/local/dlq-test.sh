#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_local_prerequisites

topic_arn="$(get_terraform_output order_events_topic_arn)"
source_queue="$(get_terraform_output payment_order_created_queue_url)"
dead_letter_queue="$(get_terraform_output payment_order_created_dlq_url)"
max_receive_count="$(get_terraform_output max_receive_count)"

suspended_mappings=()
mapfile -t suspended_mappings < <(suspend_local_event_source_mappings)
cleanup() {
    resume_local_event_source_mappings "${suspended_mappings[@]}"
}
trap cleanup EXIT

clear_local_queue "$source_queue"
clear_local_queue "$dead_letter_queue"

event_id="$(new_uuid)"
poison_message="$(jq -cn \
    --arg eventId "$event_id" \
    '{eventId: $eventId, eventType: "OrderCreated", testCase: "intentional-z1-dlq"}')"

invoke_local_aws sns publish \
    --topic-arn "$topic_arn" \
    --message "$poison_message" >/dev/null

for ((attempt = 1; attempt <= max_receive_count + 1; attempt++)); do
    message="$(receive_local_message "$source_queue" 0 1)"
    if [[ -n "$message" ]]; then
        printf 'Receive attempt %d left the message unacknowledged.\n' "$attempt"
    fi
    sleep 0.25
done

dead_letter="$(receive_local_message "$dead_letter_queue" 2 2)"
[[ -n "$dead_letter" && "$(jq -r '.Body' <<<"$dead_letter")" == *"$event_id"* ]] ||
    die "The message was not moved to the dedicated DLQ after $max_receive_count receives."

remove_local_message "$dead_letter_queue" "$(jq -r '.ReceiptHandle' <<<"$dead_letter")"
printf 'Z1 DLQ test passed. SQS redrive moved the message after %s receives.\n' "$max_receive_count"

