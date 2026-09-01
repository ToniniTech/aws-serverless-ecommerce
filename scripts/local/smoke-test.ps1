. (Join-Path $PSScriptRoot "common.ps1")

$topicArn = Get-TerraformOutput "order_events_topic_arn"
$eventBus = Get-TerraformOutput "payment_events_bus_name"
$paymentQueue = Get-TerraformOutput "payment_order_created_queue_url"
$orderNotificationQueue = Get-TerraformOutput "notification_order_created_queue_url"
$orderResultQueue = Get-TerraformOutput "order_payment_result_queue_url"
$resultNotificationQueue = Get-TerraformOutput "notification_payment_result_queue_url"

$suspendedMappings = Suspend-LocalEventSourceMappings
try {
$queues = @($paymentQueue, $orderNotificationQueue, $orderResultQueue, $resultNotificationQueue)
foreach ($queue in $queues) {
    Clear-LocalQueue -QueueUrl $queue
}

$orderEventId = [guid]::NewGuid().ToString()
$correlationId = [guid]::NewGuid().ToString()
$orderId = [guid]::NewGuid().ToString()
$orderCreated = [ordered]@{
    eventId       = $orderEventId
    eventType     = "OrderCreated"
    occurredAt    = (Get-Date).ToUniversalTime().ToString("o")
    correlationId = $correlationId
    orderId       = $orderId
    customerId    = "local-customer-001"
    totalAmount   = 19990
    currency      = "CLP"
    items         = @(@{ productId = "prod-001"; quantity = 1; unitPrice = 19990 })
} | ConvertTo-Json -Depth 6 -Compress

[void](Invoke-LocalAws -Arguments @(
    "sns", "publish",
    "--topic-arn", $topicArn,
    "--message", $orderCreated
))

foreach ($queue in @($paymentQueue, $orderNotificationQueue)) {
    $message = Receive-LocalMessage -QueueUrl $queue
    if ($null -eq $message -or $message.Body -notmatch [regex]::Escape($orderEventId)) {
        throw "SNS fan-out verification failed for $queue."
    }
    Remove-LocalMessage -QueueUrl $queue -ReceiptHandle $message.ReceiptHandle
}

$paymentEventId = [guid]::NewGuid().ToString()
$paymentDetail = [ordered]@{
    eventId       = $paymentEventId
    eventType     = "PaymentProcessed"
    occurredAt    = (Get-Date).ToUniversalTime().ToString("o")
    correlationId = $correlationId
    orderId       = $orderId
    paymentId     = [guid]::NewGuid().ToString()
    amount        = 19990
    currency      = "CLP"
} | ConvertTo-Json -Compress
$entries = ConvertTo-Json -InputObject @(@{
    Source       = "com.ecommerce.payment"
    DetailType   = "PaymentProcessed"
    Detail       = $paymentDetail
    EventBusName = $eventBus
}) -Compress

[void](Invoke-LocalAwsWithJsonInput `
    -Arguments @("events", "put-events") `
    -JsonOption "--entries" `
    -Json $entries)

foreach ($queue in @($orderResultQueue, $resultNotificationQueue)) {
    $message = Receive-LocalMessage -QueueUrl $queue
    if ($null -eq $message -or $message.Body -notmatch [regex]::Escape($paymentEventId)) {
        throw "EventBridge routing verification failed for $queue."
    }
    Remove-LocalMessage -QueueUrl $queue -ReceiptHandle $message.ReceiptHandle
}

Write-Host "Z1 smoke test passed."
Write-Host "SNS delivered one OrderCreated event to both independent SQS queues."
Write-Host "EventBridge delivered one PaymentProcessed event to both independent SQS queues."
} finally {
    Resume-LocalEventSourceMappings -MappingIds $suspendedMappings
}
