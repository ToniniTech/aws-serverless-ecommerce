. (Join-Path $PSScriptRoot "common.ps1")

function Wait-LocalLambdaReady {
    param([Parameter(Mandatory = $true)][string]$FunctionName)

    $deadline = (Get-Date).AddSeconds(60)
    do {
        $configuration = Invoke-LocalAws -Arguments @(
            "lambda", "get-function-configuration",
            "--function-name", $FunctionName,
            "--query", "{State:State,LastUpdateStatus:LastUpdateStatus}",
            "--output", "json"
        ) | ConvertFrom-Json
        if ($configuration.State -eq "Active" -and
            ($null -eq $configuration.LastUpdateStatus -or $configuration.LastUpdateStatus -eq "Successful")) {
            return
        }
        if ($configuration.LastUpdateStatus -eq "Failed") {
            throw "Local Lambda configuration update failed for $FunctionName."
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for local Lambda $FunctionName to become ready."
}

function Set-LocalLambdaEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$FunctionName,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )

    $environment = @{ Variables = $Variables } | ConvertTo-Json -Depth 8 -Compress
    [void](Invoke-LocalAwsWithJsonInput `
        -Arguments @(
            "lambda", "update-function-configuration",
            "--function-name", $FunctionName
        ) `
        -JsonOption "--environment" `
        -Json $environment)
    Wait-LocalLambdaReady -FunctionName $FunctionName
}

$orderCommandFunction = Get-TerraformOutput "order_command_function_name"
$orderOutboxFunction = Get-TerraformOutput "order_outbox_function_name"
$paymentOutboxFunction = Get-TerraformOutput "payment_outbox_function_name"

$outstandingBefore = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM order_domain.order_outbox WHERE status <> 'PUBLISHED';")
if ($outstandingBefore -ne 0) {
    throw "Outbox recovery test requires no pre-existing outstanding Order Outbox rows."
}

$currentEnvironmentJson = Invoke-LocalAws -Arguments @(
    "lambda", "get-function-configuration",
    "--function-name", $orderOutboxFunction,
    "--query", "Environment.Variables",
    "--output", "json"
)
$originalVariables = $currentEnvironmentJson | ConvertFrom-Json -AsHashtable
$failingVariables = @{}
foreach ($entry in $originalVariables.GetEnumerator()) {
    $failingVariables[$entry.Key] = $entry.Value
}
$failingVariables["ORDER_EVENTS_TOPIC_ARN"] = `
    "arn:aws:sns:us-east-1:000000000000:missing-z4-$([guid]::NewGuid())"

$correlationId = "local-outbox-recovery-$([guid]::NewGuid())"
$idempotencyKey = "local-outbox-recovery-request-$([guid]::NewGuid())"
$requestBody = @{
    items = @(@{ productId = "prod-002"; quantity = 1 })
} | ConvertTo-Json -Depth 5 -Compress
$createEvent = @{
    version         = "2.0"
    routeKey        = "POST /orders"
    rawPath         = "/orders"
    headers         = @{
        "content-type"       = "application/json"
        "x-customer-id"      = "local-outbox-customer"
        "x-customer-email"   = "outbox.customer@example.test"
        "x-correlation-id"   = $correlationId
        "idempotency-key"    = $idempotencyKey
    }
    body            = $requestBody
    isBase64Encoded = $false
} | ConvertTo-Json -Depth 8 -Compress

$createResponse = (Invoke-LocalLambda -FunctionName $orderCommandFunction -Payload $createEvent) |
    ConvertFrom-Json
if ($createResponse.statusCode -ne 201) {
    throw "Order Command returned $($createResponse.statusCode): $($createResponse.body)"
}
$orderId = ($createResponse.body | ConvertFrom-Json).orderId

$expectedFailure = $false
try {
    Set-LocalLambdaEnvironment -FunctionName $orderOutboxFunction -Variables $failingVariables
    try {
        [void](Invoke-LocalLambda -FunctionName $orderOutboxFunction -Payload "{}")
    } catch {
        $expectedFailure = $true
    }

    if (-not $expectedFailure) {
        throw "Order Outbox unexpectedly published to a nonexistent SNS topic."
    }

    $failedState = Invoke-LocalPostgresScalar -Sql `
        "SELECT status || '|' || attempt_count || '|' || (last_error IS NOT NULL) FROM order_domain.order_outbox WHERE aggregate_id = '$orderId';"
    if ($failedState -ne "PENDING|1|true") {
        throw "Order Outbox was not safely released after publication failure: $failedState"
    }
} finally {
    Set-LocalLambdaEnvironment -FunctionName $orderOutboxFunction -Variables $originalVariables
}

# The first backoff is one second. Restoring the Lambda configuration normally exceeds it, but this
# loop makes the assertion independent of local machine speed.
$retryDeadline = (Get-Date).AddSeconds(15)
do {
    $readyToRetry = Invoke-LocalPostgresScalar -Sql `
        "SELECT (next_attempt_at <= CURRENT_TIMESTAMP)::text FROM order_domain.order_outbox WHERE aggregate_id = '$orderId';"
    if ($readyToRetry -eq "true") {
        break
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $retryDeadline)
if ($readyToRetry -ne "true") {
    throw "Order Outbox row did not become eligible for retry."
}

$recoveredResult = (Invoke-LocalLambda -FunctionName $orderOutboxFunction -Payload "{}") |
    ConvertFrom-Json
if ($recoveredResult.published -lt 1) {
    throw "Order Outbox did not publish after SNS recovery."
}
$recoveredState = Invoke-LocalPostgresScalar -Sql `
    "SELECT status || '|' || attempt_count FROM order_domain.order_outbox WHERE aggregate_id = '$orderId';"
if ($recoveredState -ne "PUBLISHED|2") {
    throw "Unexpected recovered Order Outbox state: $recoveredState"
}

$paymentDeadline = (Get-Date).AddSeconds(90)
do {
    $paymentOutboxCount = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT count(*) FROM payment_outbox WHERE aggregate_id = '$orderId';")
    if ($paymentOutboxCount -eq 1) {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $paymentDeadline)
if ($paymentOutboxCount -ne 1) {
    throw "Recovered Order event did not reach Payment."
}

$paymentPublish = (Invoke-LocalLambda -FunctionName $paymentOutboxFunction -Payload "{}") |
    ConvertFrom-Json
if ($paymentPublish.published -lt 1) {
    throw "Payment Outbox did not finish the recovery scenario."
}

$orderDeadline = (Get-Date).AddSeconds(90)
do {
    $orderStatus = Invoke-LocalPostgresScalar -Sql `
        "SELECT status FROM order_domain.orders WHERE order_id = '$orderId';"
    if ($orderStatus -eq "PAID") {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $orderDeadline)
if ($orderStatus -ne "PAID") {
    throw "Recovered event did not complete the Order flow."
}

Write-Host "Z4 Order Outbox recovery test passed."
Write-Host "Order ID: $orderId"
Write-Host "Failed publication state: PENDING / attempt 1"
Write-Host "Recovered publication state: PUBLISHED / attempt 2"
Write-Host "Final Order status: $orderStatus"
