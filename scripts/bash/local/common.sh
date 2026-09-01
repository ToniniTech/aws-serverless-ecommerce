#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
TERRAFORM_ROOT="$REPOSITORY_ROOT/infrastructure/terraform/local"
WINDOWS_TERRAFORM="$REPOSITORY_ROOT/.tools/terraform-1.15.8/terraform.exe"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command was not found: $command_name"
}

enter_repository_root() {
    cd -- "$REPOSITORY_ROOT"
}

get_local_terraform() {
    if command -v terraform >/dev/null 2>&1; then
        command -v terraform
        return
    fi

    case "${OSTYPE:-}" in
        msys*|cygwin*)
            if [[ -f "$WINDOWS_TERRAFORM" ]]; then
                printf '%s\n' "$WINDOWS_TERRAFORM"
                return
            fi
            ;;
    esac

    die "Terraform was not found. Install the Linux Terraform CLI in WSL2 (version 1.9 or newer)."
}

get_terraform_output() {
    local name="$1"
    local terraform
    terraform="$(get_local_terraform)"
    "$terraform" "-chdir=$TERRAFORM_ROOT" output -raw "$name"
}

invoke_local_aws() {
    enter_repository_root
    docker compose exec -T localstack awslocal "$@"
}

invoke_local_aws_with_json_input() {
    local json_option="$1"
    local json="$2"
    shift 2

    enter_repository_root
    printf '%s' "$json" |
        docker compose exec -T localstack awslocal "$@" "$json_option" file:///dev/stdin
}

clear_local_queue() {
    local queue_url="$1"
    invoke_local_aws sqs purge-queue --queue-url "$queue_url" >/dev/null
}

receive_local_message() {
  local queue_url="$1"
  local visibility_timeout="${2:-2}"
  local wait_time_seconds="${3:-2}"
  local response

  response="$(invoke_local_aws sqs receive-message \
       --queue-url "$queue_url" \
       --max-number-of-messages 1 \
       --visibility-timeout "$visibility_timeout" \
       --wait-time-seconds "$wait_time_seconds" \
       --attribute-names All)"

  if [[ -z "$response" ]]; then
    return 0
  fi

  jq -c '.message[0] // empty' <<<"$response"

  }

remove_local_message() {
    local queue_url="$1"
    local receipt_handle="$2"

    invoke_local_aws sqs delete-message \
    --queue-url "$queue_url"\
    --receipt-handle "$receipt_handle" >/dev/null
}

invoke_local_lambda() {
    local function_name="$1"
    local payload="$2"
    local remote_output="/tmp/lambda-$(new_uuid_compact).json"
    local metadata_json
    local payload_text

    enter_repository_root
    if ! metadata_json="$(printf '%s' "$payload" |
        docker compose exec -T localstack awslocal lambda invoke \
            --function-name "$function_name" \
            --payload file:///dev/stdin \
            "$remote_output")"; then
        printf 'Local Lambda invocation failed: %s\n' "$function_name" >&2
        return 1
    fi

    if ! payload_text="$(docker compose exec -T localstack cat "$remote_output")"; then
        printf 'Could not read the local Lambda response: %s\n' "$function_name" >&2
        return 1
    fi
    docker compose exec -T localstack rm -f "$remote_output" >/dev/null

    if [[ "$(jq -r '.FunctionError // empty' <<<"$metadata_json")" != "" ]]; then
        printf 'Local Lambda %s failed: %s\n' "$function_name" "$payload_text" >&2
        return 1
    fi

    printf '%s\n' "$payload_text"
}

invoke_local_postgres_scalar() {
    local sql="$1"
    local result

    enter_repository_root
    result="$(docker compose exec -T payment-postgres \
        psql -U payment_local -d payments -v ON_ERROR_STOP=1 -tAc "$sql")"
    printf '%s' "$result" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

suspend_local_event_source_mappings() {
    local mappings_json
    local mapping_id
    local suspended=()

    mappings_json="$(invoke_local_aws lambda list-event-source-mappings \
        --query 'EventSourceMappings[].{UUID:UUID,State:State}' \
        --output json)"

    while IFS= read -r mapping_id; do
        [[ -z "$mapping_id" ]] && continue
        invoke_local_aws lambda update-event-source-mapping \
            --uuid "$mapping_id" \
            --no-enabled >/dev/null
        suspended+=("$mapping_id")
    done < <(jq -r '.[] | select(.State == "Enabled") | .UUID' <<<"$mappings_json")

    if ((${#suspended[@]} > 0)); then
        sleep 1
        printf '%s\n' "${suspended[@]}"
    fi
}

resume_local_event_source_mappings() {
    local mapping_id
    for mapping_id in "$@"; do
        [[ -z "$mapping_id" ]] && continue
        invoke_local_aws lambda update-event-source-mapping \
            --uuid "$mapping_id" \
            --enabled >/dev/null
    done
}

new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr -d '\n' </proc/sys/kernel/random/uuid
        return
    fi

    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\n'
        return
    fi

    if command -v openssl >/dev/null 2>&1; then
        local random_hex
        random_hex="$(openssl rand -hex 16)"
        printf '%s-%s-4%s-8%s-%s' \
            "${random_hex:0:8}" \
            "${random_hex:8:4}" \
            "${random_hex:13:3}" \
            "${random_hex:17:3}" \
            "${random_hex:20:12}"
        return
    fi

    die "A UUID source was not found. Install uuid-runtime or openssl."
}

new_uuid_compact() {
    new_uuid | tr -d '-'
}

utc_timestamp() {
    date -u +'%Y-%m-%dT%H:%M:%S.%3NZ'
}

epoch_seconds() {
    date +%s
}

require_local_prerequisites() {
    require_command docker
    require_command jq
}
