#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
enter_repository_root

curl --fail --silent --show-error --max-time 5 \
    http://localhost:4566/_localstack/health >/dev/null ||
    die "LocalStack is not reachable. Run scripts/bash/local/start.sh first."

terraform="$(get_local_terraform)"
"$terraform" "-chdir=$TERRAFORM_ROOT" init
"$terraform" "-chdir=$TERRAFORM_ROOT" apply -auto-approve

printf 'Local messaging, Lambda, and Step Functions resources are provisioned.\n'
printf 'Endpoint: http://localhost:4566 (fake account 000000000000)\n'

