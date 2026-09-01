. (Join-Path $PSScriptRoot "common.ps1")

$orderCommandFunction = Get-TerraformOutput "order_command_function_name"
$orderQueryFunction = Get-TerraformOutput "order_query_function_name"
$orderOutboxFunction = Get-TerraformOutput "order_outbox_function_name"
$paymentOutboxFunction = Get-TerraformOutput "payment_outbox_function_name"
$notificationFunction = Get-TerraformOutput "notification_function_name"

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

$correlationId = "local-$([guid]::NewGuid())"
$idempotencyKey = "local-request-$([guid]::NewGuid())"
$requestBody = @{
    items = @(@{ productId = "prod-001"; quantity = 1 })
} | ConvertTo-Json -Depth 5 -Compress
$createEvent = @{
    version         = "2.0"
    routeKey        = "POST /orders"
    rawPath         = "/orders"
    headers         = @{
        "content-type"       = "application/json"
        "x-customer-id"      = "local-customer-001"
        "x-customer-email"   = "local.customer@example.test"
        "x-correlation-id"   = $correlationId
        "idempotency-key"    = $idempotencyKey
    }
    body            = $requestBody
    isBase64Encoded = $false
} | ConvertTo-Json -Depth 8 -Compress

$createPayload = Invoke-LocalLambda -FunctionName $orderCommandFunction -Payload $createEvent
$createResponse = $createPayload | ConvertFrom-Json
if ($createResponse.statusCode -ne 201) {
    throw "Order Command returned $($createResponse.statusCode): $($createResponse.body)"
}
$createdOrder = $createResponse.body | ConvertFrom-Json
$orderId = $createdOrder.orderId

$orderOutboxPayload = Invoke-LocalLambda -FunctionName $orderOutboxFunction -Payload "{}"
$orderOutboxResult = $orderOutboxPayload | ConvertFrom-Json
if ($orderOutboxResult.published -lt 1) {
    throw "Order Outbox did not publish the OrderCreated event: $orderOutboxPayload"
}

$paymentDeadline = (Get-Date).AddSeconds(90)
do {
    $paymentOutboxCount = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT count(*) FROM payment_outbox WHERE aggregate_id = '$orderId';")
    if ($paymentOutboxCount -gt 0) {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $paymentDeadline)
if ($paymentOutboxCount -eq 0) {
    throw "Payment Lambda did not persist a Payment Outbox event for Order $orderId."
}

$paymentOutboxPayload = Invoke-LocalLambda -FunctionName $paymentOutboxFunction -Payload "{}"
$paymentOutboxResult = $paymentOutboxPayload | ConvertFrom-Json
if ($paymentOutboxResult.published -lt 1) {
    throw "Payment Outbox did not publish a payment result: $paymentOutboxPayload"
}

$orderDeadline = (Get-Date).AddSeconds(90)
$status = "PENDING"
do {
    $status = Invoke-LocalPostgresScalar -Sql `
        "SELECT status FROM order_domain.orders WHERE order_id = '$orderId';"
    if ($status -eq "PAID" -or $status -eq "FAILED") {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $orderDeadline)
if ($status -ne "PAID") {
    throw "Expected Order $orderId to become PAID, but its status is $status."
}

$queryEvent = @{
    version        = "2.0"
    routeKey       = "GET /orders/{orderId}"
    rawPath        = "/orders/$orderId"
    pathParameters = @{ orderId = $orderId }
} | ConvertTo-Json -Depth 5 -Compress
$queryPayload = Invoke-LocalLambda -FunctionName $orderQueryFunction -Payload $queryEvent
$queryResponse = $queryPayload | ConvertFrom-Json
$orderView = $queryResponse.body | ConvertFrom-Json
if ($queryResponse.statusCode -ne 200 -or $orderView.status -ne "PAID") {
    throw "Order Query did not return the expected PAID projection: $queryPayload"
}

$notificationDeadline = (Get-Date).AddSeconds(90)
$notificationCount = 0
do {
    $notificationSchemaReady = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT CASE WHEN to_regclass('notification_domain.notifications') IS NULL THEN 0 ELSE 1 END;")
    if ($notificationSchemaReady -eq 1) {
        $notificationCount = [int](Invoke-LocalPostgresScalar -Sql `
            "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$orderId';")
    }
    if ($notificationCount -eq 2) {
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $notificationDeadline)
if ($notificationCount -ne 2) {
    throw "Expected two Notification records for Order $orderId, but found $notificationCount."
}

$orderCreatedPayload = Invoke-LocalPostgresScalar -Sql `
    "SELECT payload::text FROM order_domain.order_outbox WHERE aggregate_id = '$orderId' AND event_type = 'OrderCreated' LIMIT 1;"
$duplicateNotificationEvent = @{
    Records = @(@{
        messageId         = "duplicate-$([guid]::NewGuid())"
        body              = $orderCreatedPayload
        attributes        = @{ ApproximateReceiveCount = "2" }
        messageAttributes = @{}
    })
} | ConvertTo-Json -Depth 10 -Compress
$duplicatePayload = Invoke-LocalLambda `
    -FunctionName $notificationFunction `
    -Payload $duplicateNotificationEvent
$duplicateResponse = $duplicatePayload | ConvertFrom-Json
if ($duplicateResponse.batchItemFailures.Count -ne 0) {
    throw "Notification duplicate was returned as a batch failure: $duplicatePayload"
}
$notificationCountAfterDuplicate = [int](Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM notification_domain.notifications WHERE order_id = '$orderId';")
if ($notificationCountAfterDuplicate -ne 2) {
    throw "Notification duplicate created an extra row for Order $orderId."
}

$paymentStatus = Invoke-LocalPostgresScalar -Sql `
    "SELECT status FROM payments WHERE order_id = '$orderId';"
$processedPaymentEvents = Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM processed_events WHERE order_id = '$orderId';"
$processedOrderEvents = Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM order_domain.order_processed_events WHERE order_id = '$orderId';"
$processedNotificationEvents = Invoke-LocalPostgresScalar -Sql `
    "SELECT count(*) FROM notification_domain.notification_processed_events WHERE order_id = '$orderId';"

Write-Host "Z3 happy path and Notification duplicate replay passed."
Write-Host "Order ID: $orderId"
Write-Host "Payment status: $paymentStatus"
Write-Host "Order status: $($orderView.status)"
Write-Host "Payment processed-event rows: $processedPaymentEvents"
Write-Host "Order processed-event rows: $processedOrderEvents"
Write-Host "Notification rows: $notificationCountAfterDuplicate"
Write-Host "Notification processed-event rows: $processedNotificationEvents"
