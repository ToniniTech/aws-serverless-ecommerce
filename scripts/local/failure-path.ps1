. (Join-Path $PSScriptRoot "common.ps1")

$orderCommandFunction = Get-TerraformOutput "order_command_function_name"
$orderQueryFunction = Get-TerraformOutput "order_query_function_name"
$orderOutboxFunction = Get-TerraformOutput "order_outbox_function_name"
$paymentOutboxFunction = Get-TerraformOutput "payment_outbox_function_name"
$paymentEventBus = Get-TerraformOutput "payment_events_bus_name"

$queuesToClear = @(
    (Get-TerraformOutput "payment_order_created_queue_url"),
    (Get-TerraformOutput "payment_order_created_dlq_url"),
    (Get-TerraformOutput "notification_order_created_queue_url"),
    (Get-TerraformOutput "notification_order_created_dlq_url"),
    (Get-TerraformOutput "order_payment_result_queue_url"),
    (Get-TerraformOutput "order_payment_result_dlq_url"),
    (Get-TerraformOutput "notification_payment_result_queue_url"),
    (Get-TerraformOutput "notification_payment_result_dlq_url")
)
foreach ($queue in $queuesToClear) {
    Clear-LocalQueue -QueueUrl $queue
}

$correlationId = "local-failure-$([guid]::NewGuid())"
$idempotencyKey = "local-failure-request-$([guid]::NewGuid())"
$requestBody = @{
    items = @(@{ productId = "prod-001"; quantity = 8 })
} | ConvertTo-Json -Depth 5 -Compress
$createEvent = @{
    version         = "2.0"
    routeKey        = "POST /orders"
    rawPath         = "/orders"
    headers         = @{
        "content-type"       = "application/json"
        "x-customer-id"      = "local-failure-customer"
        "x-customer-email"   = "failure.customer@example.test"
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

$orderOutboxResult = (Invoke-LocalLambda -FunctionName $orderOutboxFunction -Payload "{}") |
    ConvertFrom-Json
if ($orderOutboxResult.published -lt 1) {
    throw "Order Outbox did not publish OrderCreated for $orderId."
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
    throw "Payment did not persist exactly one Outbox event for $orderId."
}

$paymentStatus = Invoke-LocalPostgresScalar -Sql `
    "SELECT status FROM payments WHERE order_id = '$orderId';"
$paymentFailureCode = Invoke-LocalPostgresScalar -Sql `
    "SELECT failure_code FROM payments WHERE order_id = '$orderId';"
if ($paymentStatus -ne "FAILED" -or $paymentFailureCode -ne "AMOUNT_EXCEEDS_LIMIT") {
    throw "Expected deterministic Payment failure, got $paymentStatus / $paymentFailureCode."
}

$paymentOutboxResult = (Invoke-LocalLambda -FunctionName $paymentOutboxFunction -Payload "{}") |
    ConvertFrom-Json
if ($paymentOutboxResult.published -lt 1) {
    throw "Payment Outbox did not publish PaymentFailed for $orderId."
}

$resultDeadline = (Get-Date).AddSeconds(90)
do {
    $orderStatus = Invoke-LocalPostgresScalar -Sql `
        "SELECT status FROM order_domain.orders WHERE order_id = '$orderId';"
    $notificationCount = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$orderId';")
    if ($orderStatus -eq "FAILED" -and $notificationCount -eq 2) {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $resultDeadline)
if ($orderStatus -ne "FAILED" -or $notificationCount -ne 2) {
    throw "Failure path did not converge: order=$orderStatus notifications=$notificationCount."
}

$orderFailureCode = Invoke-LocalPostgresScalar -Sql `
    "SELECT payment_failure_code FROM order_domain.orders WHERE order_id = '$orderId';"
$notificationTemplates = Invoke-LocalPostgresScalar -Sql `
    "SELECT string_agg(template_key, ',' ORDER BY template_key) FROM notification_domain.notifications WHERE order_id = '$orderId';"
if ($orderFailureCode -ne "AMOUNT_EXCEEDS_LIMIT") {
    throw "Order did not retain the Payment failure code."
}
if ($notificationTemplates -ne "ORDER_CREATED,PAYMENT_FAILED") {
    throw "Unexpected Notification templates: $notificationTemplates"
}

$paymentEventType = Invoke-LocalPostgresScalar -Sql `
    "SELECT event_type FROM payment_outbox WHERE aggregate_id = '$orderId';"
$paymentEventDetail = Invoke-LocalPostgresScalar -Sql `
    "SELECT payload::text FROM payment_outbox WHERE aggregate_id = '$orderId';"
$duplicateEntry = ConvertTo-Json -InputObject @(@{
    Source       = "com.ecommerce.payment"
    DetailType   = $paymentEventType
    Detail       = $paymentEventDetail
    EventBusName = $paymentEventBus
}) -Depth 8 -Compress
$duplicatePublish = Invoke-LocalAwsWithJsonInput `
    -Arguments @("events", "put-events") `
    -JsonOption "--entries" `
    -Json $duplicateEntry | ConvertFrom-Json
if ($duplicatePublish.FailedEntryCount -ne 0) {
    throw "EventBridge rejected the duplicate Payment result."
}

# EventBridge target delivery is asynchronous even in the emulator. Give both warm consumers time
# to handle the deliberate replay before asserting that no durable effect was repeated.
Start-Sleep -Seconds 5
$orderVersion = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT version FROM order_domain.orders WHERE order_id = '$orderId';")
$orderProcessedCount = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM order_domain.order_processed_events WHERE order_id = '$orderId';")
$notificationCountAfterReplay = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$orderId';")
$notificationProcessedCount = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM notification_domain.notification_processed_events WHERE order_id = '$orderId';")
if ($orderVersion -ne 1 -or $orderProcessedCount -ne 1) {
    throw "Duplicate PaymentFailed repeated the Order effect."
}
if ($notificationCountAfterReplay -ne 2 -or $notificationProcessedCount -ne 2) {
    throw "Duplicate PaymentFailed repeated the Notification effect."
}

$queryEvent = @{
    version        = "2.0"
    routeKey       = "GET /orders/{orderId}"
    rawPath        = "/orders/$orderId"
    pathParameters = @{ orderId = $orderId }
} | ConvertTo-Json -Depth 5 -Compress
$queryResponse = (Invoke-LocalLambda -FunctionName $orderQueryFunction -Payload $queryEvent) |
    ConvertFrom-Json
$orderView = $queryResponse.body | ConvertFrom-Json
if ($queryResponse.statusCode -ne 200 -or $orderView.status -ne "FAILED") {
    throw "Order Query did not expose the final FAILED state."
}

Write-Host "Z4 failure path and duplicate PaymentFailed replay passed."
Write-Host "Order ID: $orderId"
Write-Host "Payment: $paymentStatus / $paymentFailureCode"
Write-Host "Order: $($orderView.status) / $orderFailureCode / version $orderVersion"
Write-Host "Notifications: $notificationCountAfterReplay ($notificationTemplates)"
