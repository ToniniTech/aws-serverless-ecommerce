$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "failure-path.ps1")
& (Join-Path $PSScriptRoot "outbox-recovery-test.ps1")
& (Join-Path $PSScriptRoot "consumer-dlq-test.ps1")

Write-Host "Z4 local resilience suite passed. No AWS account was contacted."
