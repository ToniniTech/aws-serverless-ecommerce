#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

skip_tests=false
case "${1:-}" in
    "") ;;
    --skip-tests) skip_tests=true ;;
    *) die "Usage: $0 [--skip-tests]" ;;
esac

enter_repository_root
arguments=(clean package)
if [[ "$skip_tests" == true ]]; then
    arguments+=(-DskipTests)
fi

if [[ -x "$REPOSITORY_ROOT/mvnw" ]]; then
    "$REPOSITORY_ROOT/mvnw" "${arguments[@]}"
else
    bash "$REPOSITORY_ROOT/mvnw" "${arguments[@]}"
fi

artifacts=(
    "payment-order-created-lambda/target/payment-order-created-lambda.jar"
    "order-payment-result-lambda/target/order-payment-result-lambda.jar"
    "notification-demo-lambda/target/notification-demo-lambda.jar"
    "saga-orchestration-lambda/target/saga-orchestration-lambda.jar"
)

for artifact in "${artifacts[@]}"; do
    [[ -f "$REPOSITORY_ROOT/$artifact" ]] || die "Expected Lambda artifact was not created: $artifact"
done

printf 'All shaded Java Lambda artifacts are ready.\n'

