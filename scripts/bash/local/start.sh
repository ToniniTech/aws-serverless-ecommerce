#!/usr/bin/env bash

set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command docker
enter_repository_root

token_configured=false
if [[ -n "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
    token_configured=true
elif [[ -f "$REPOSITORY_ROOT/.env" ]] && grep -Eq '^LOCALSTACK_AUTH_TOKEN=.+$' "$REPOSITORY_ROOT/.env"; then
    token_configured=true
fi

[[ "$token_configured" == true ]] || die \
    "LOCALSTACK_AUTH_TOKEN is missing. Copy .env.example to .env and add a free Hobby token."

docker info >/dev/null 2>&1 || die "Docker Engine is not available."
docker compose up -d payment-postgres localstack

containers=(
    serverless-ecommerce-payment-postgres
    serverless-ecommerce-localstack
)
deadline=$(( $(epoch_seconds) + 60 ))

for container in "${containers[@]}"; do
    status=""
    while (( $(epoch_seconds) < deadline )); do
        status="$(docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$container")"
        if [[ "$status" == "healthy" ]]; then
            break
        fi
        if [[ "$status" == "exited" || "$status" == "dead" ]]; then
            die "$container stopped before becoming healthy. Run 'docker compose logs $container'."
        fi
        sleep 2
    done

    [[ "$status" == "healthy" ]] || die "$container did not become healthy within 60 seconds."
done

printf 'PostgreSQL and LocalStack are healthy. No AWS account was contacted.\n'

