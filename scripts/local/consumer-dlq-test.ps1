. (Join-Path $PSScriptRoot "common.ps1")

$sourceQueue = Get-TerraformOutput "notification_order_created_queue_url"
$deadLetterQueue = Get-TerraformOutput "notification_order_created_dlq_url"
$maxReceiveCount = [int](Get-TerraformOutput "max_receive_count")

$originalVisibility = Invoke-LocalAws -Arguments @(
    "sqs", "get-queue-attributes",
    "--queue-url", $sourceQueue,
    "--attribute-names", "VisibilityTimeout",
    "--query", "Attributes.VisibilityTimeout",
    "--output", "text"
)

Clear-LocalQueue -QueueUrl $sourceQueue
Clear-LocalQueue -QueueUrl $deadLetterQueue

$eventId = [guid]::NewGuid().ToString()
$orderId = "order-dlq-$([guid]::NewGuid())"
$event = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "examples/order-created.json") |
    ConvertFrom-Json
$event.eventId = $eventId
$event.orderId = $orderId
$event.correlationId = "correlation-$eventId"
$event.occurredAt = (Get-Date).ToUniversalTime().ToString("o")
$messageBody = $event | ConvertTo-Json -Depth 8 -Compress
$failureAttribute = @{
    forceFailure = @{
        DataType    = "String"
        StringValue = "true"
    }
} | ConvertTo-Json -Depth 4 -Compress

try {
    [void](Invoke-LocalAws -Arguments @(
        "sqs", "set-queue-attributes",
        "--queue-url", $sourceQueue,
        "--attributes", "VisibilityTimeout=2"
    ))

    [void](Invoke-LocalAwsWithJsonInput `
        -Arguments @(
            "sqs", "send-message",
            "--queue-url", $sourceQueue,
            "--message-attributes", $failureAttribute
        ) `
        -JsonOption "--message-body" `
        -Json $messageBody)

    $deadline = (Get-Date).AddSeconds(60)
    $deadLetter = $null
    do {
        $deadLetter = Receive-LocalMessage `
            -QueueUrl $deadLetterQueue `
            -VisibilityTimeout 5 `
            -WaitTimeSeconds 1
        if ($null -ne $deadLetter) {
            break
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $deadLetter -or $deadLetter.Body -notmatch [regex]::Escape($eventId)) {
        throw "Notification failure did not reach its DLQ after $maxReceiveCount receives."
    }

    $notificationCount = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT count(*) FROM notification_domain.notifications WHERE event_id = '$eventId';")
    $processedCount = [int](Invoke-LocalPostgresScalar -Sql `
        "SELECT count(*) FROM notification_domain.notification_processed_events WHERE event_id = '$eventId';")
    if ($notificationCount -ne 0 -or $processedCount -ne 0) {
        throw "The intentionally failed event crossed the Notification transaction boundary."
    }

    Remove-LocalMessage -QueueUrl $deadLetterQueue -ReceiptHandle $deadLetter.ReceiptHandle
    Write-Host "Z4 Lambda retry and DLQ test passed."
    Write-Host "Event ID: $eventId"
    Write-Host "SQS redrove the failed record after maxReceiveCount=$maxReceiveCount."
    Write-Host "Notification and ProcessedEvent rows: 0"
} finally {
    [void](Invoke-LocalAws -Arguments @(
        "sqs", "set-queue-attributes",
        "--queue-url", $sourceQueue,
        "--attributes", "VisibilityTimeout=$originalVisibility"
    ))
}
