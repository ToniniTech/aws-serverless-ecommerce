. (Join-Path $PSScriptRoot "common.ps1")

function Start-SagaExecution {
    param(
        [Parameter(Mandatory = $true)][string]$StateMachineArn,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )
    $name = "saga-$([guid]::NewGuid().ToString('N'))"
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $started = Invoke-LocalAwsWithJsonInput `
        -Arguments @("stepfunctions", "start-execution", "--state-machine-arn", $StateMachineArn, "--name", $name) `
        -JsonOption "--input" `
        -Json $json | ConvertFrom-Json
    return $started.executionArn
}

function Wait-SagaExecution {
    param([Parameter(Mandatory = $true)][string]$ExecutionArn)
    $deadline = (Get-Date).AddSeconds(180)
    do {
        $execution = Invoke-LocalAws -Arguments @(
            "stepfunctions", "describe-execution", "--execution-arn", $ExecutionArn
        ) | ConvertFrom-Json
        if ($execution.status -in @("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED")) {
            return $execution
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for Saga execution $ExecutionArn."
}

$stateMachineArn = Get-TerraformOutput "order_saga_state_machine_arn"

$successSagaId = "saga-success-$([guid]::NewGuid())"
$successOrderId = "saga-order-success-$([guid]::NewGuid())"
$successInput = @{
    sagaId = $successSagaId; orderId = $successOrderId; productId = "prod-001";
    quantity = 1; amount = 129.99; currency = "USD"
}
$successArn = Start-SagaExecution -StateMachineArn $stateMachineArn -Payload $successInput
$success = Wait-SagaExecution -ExecutionArn $successArn
if ($success.status -ne "SUCCEEDED") {
    throw "Successful Saga execution ended as $($success.status): $($success.cause)"
}
$successOutput = $success.output | ConvertFrom-Json
if ($successOutput.confirmation.value.orderStatus -ne "CONFIRMED") {
    throw "Successful Saga did not confirm the Order."
}
$keyboardAfterFirstExecution = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-001';")

$duplicateSuccessArn = Start-SagaExecution -StateMachineArn $stateMachineArn -Payload $successInput
$duplicateSuccess = Wait-SagaExecution -ExecutionArn $duplicateSuccessArn
if ($duplicateSuccess.status -ne "SUCCEEDED") {
    throw "Duplicate successful Saga ended as $($duplicateSuccess.status): $($duplicateSuccess.cause)"
}
$keyboardAfterDuplicate = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-001';")
if ($keyboardAfterDuplicate -ne $keyboardAfterFirstExecution) {
    throw "Duplicate successful Saga decremented stock more than once."
}
$successReservationCount = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM saga_demo.saga_stock_reservations WHERE saga_id = '$successSagaId' AND quantity = 1 AND status = 'RESERVED';")
if ($successReservationCount -ne 1) {
    throw "Successful Saga did not persist exactly one active stock reservation."
}

$failedSagaId = "saga-failed-$([guid]::NewGuid())"
$failedOrderId = "saga-order-failed-$([guid]::NewGuid())"
$mouseBefore = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")
$failedInput = @{
    sagaId = $failedSagaId; orderId = $failedOrderId; productId = "prod-002";
    quantity = 1; amount = 100.13; currency = "USD"
}
$failedArn = Start-SagaExecution -StateMachineArn $stateMachineArn -Payload $failedInput
$failed = Wait-SagaExecution -ExecutionArn $failedArn
if ($failed.status -ne "SUCCEEDED") {
    throw "Compensated Saga execution ended as $($failed.status): $($failed.cause)"
}
$failedOutput = $failed.output | ConvertFrom-Json
if ($failedOutput.payment.value.failureCode -ne "CARD_EXPIRED" -or
    $failedOutput.compensation.value.reservationStatus -ne "COMPENSATED") {
    throw "Failed Payment did not execute the expected stock compensation."
}
$mouseAfter = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")
if ($mouseAfter -ne $mouseBefore) {
    throw "Compensated Saga did not restore stock."
}
$duplicateFailedArn = Start-SagaExecution -StateMachineArn $stateMachineArn -Payload $failedInput
$duplicateFailed = Wait-SagaExecution -ExecutionArn $duplicateFailedArn
if ($duplicateFailed.status -ne "SUCCEEDED") {
    throw "Duplicate compensated Saga ended as $($duplicateFailed.status): $($duplicateFailed.cause)"
}
$mouseAfterDuplicate = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT available_stock FROM saga_demo.saga_inventory_products WHERE product_id = 'prod-002';")
if ($mouseAfterDuplicate -ne $mouseBefore) {
    throw "Duplicate compensated Saga changed stock."
}
$failedOrderCount = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM saga_demo.saga_orders WHERE saga_id = '$failedSagaId';")
if ($failedOrderCount -ne 0) {
    throw "Compensated Saga created a confirmed Order."
}

Write-Host "Z5 local Step Functions Saga passed."
Write-Host "Success: Order CONFIRMED; duplicate execution kept stock at $keyboardAfterDuplicate."
Write-Host "Payment failure: stock $mouseBefore -> $mouseAfterDuplicate, reservation COMPENSATED; duplicate was harmless."
Write-Host "State machine: $stateMachineArn"
