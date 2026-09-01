#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/failure-path.sh"
bash "$SCRIPT_DIR/outbox-recovery-test.sh"
bash "$SCRIPT_DIR/consumer-dlq-test.sh"

printf 'Z4 local resilience suite passed. No AWS account was contacted.\n'
