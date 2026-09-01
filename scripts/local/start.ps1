. (Join-Path $PSScriptRoot "common.ps1")

Enter-RepositoryRoot

$tokenConfigured = -not [string]::IsNullOrWhiteSpace($env:LOCALSTACK_AUTH_TOKEN)
$environmentFile = Join-Path $script:RepositoryRoot ".env"
if (-not $tokenConfigured -and (Test-Path -LiteralPath $environmentFile)) {
    $tokenConfigured = Select-String -LiteralPath $environmentFile -Pattern '^LOCALSTACK_AUTH_TOKEN=.+$' -Quiet
}
if (-not $tokenConfigured) {
    throw "LOCALSTACK_AUTH_TOKEN is missing. Copy .env.example to .env and add a free Hobby token."
}

& docker info *> $null
Assert-CommandSucceeded "Checking Docker Engine"

& docker compose up -d payment-postgres localstack
Assert-CommandSucceeded "Starting PostgreSQL and LocalStack"

$containers = @(
    "serverless-ecommerce-payment-postgres",
    "serverless-ecommerce-localstack"
)
$deadline = (Get-Date).AddSeconds(60)
foreach ($container in $containers) {
    do {
        $status = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $container).Trim()
        Assert-CommandSucceeded "Inspecting $container"
        if ($status -eq "healthy") {
            break
        }
        if ($status -eq "exited" -or $status -eq "dead") {
            throw "$container stopped before becoming healthy. Run 'docker compose logs $container'."
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    if ($status -ne "healthy") {
        throw "$container did not become healthy within 60 seconds."
    }
}

Write-Host "PostgreSQL and LocalStack are healthy. No AWS account was contacted."
