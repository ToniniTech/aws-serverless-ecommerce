. (Join-Path $PSScriptRoot "common.ps1")

$topicArn = Get-TerraformOutput "order_events_topic_arn"
$sourceQueue = Get-TerraformOutput "payment_order_created_queue_url"
$deadLetterQueue = Get-TerraformOutput "payment_order_created_dlq_url"
$maxReceiveCount = [int](Get-TerraformOutput "max_receive_count")

$suspendedMappings = Suspend-LocalEventSourceMappings
try {
Clear-LocalQueue -QueueUrl $sourceQueue
Clear-LocalQueue -QueueUrl $deadLetterQueue

$eventId = [guid]::NewGuid().ToString()
$poisonMessage = @{
    eventId   = $eventId
    eventType = "OrderCreated"
    testCase  = "intentional-z1-dlq"
} | ConvertTo-Json -Compress

[void](Invoke-LocalAws -Arguments @(
    "sns", "publish",
    "--topic-arn", $topicArn,
    "--message", $poisonMessage
))

for ($attempt = 1; $attempt -le ($maxReceiveCount + 1); $attempt++) {
    $message = Receive-LocalMessage -QueueUrl $sourceQueue -VisibilityTimeout 0 -WaitTimeSeconds 1
    if ($null -ne $message) {
        Write-Host "Receive attempt $attempt left the message unacknowledged."
    }
    Start-Sleep -Milliseconds 250
}

$deadLetter = Receive-LocalMessage -QueueUrl $deadLetterQueue -VisibilityTimeout 2 -WaitTimeSeconds 2
if ($null -eq $deadLetter -or $deadLetter.Body -notmatch [regex]::Escape($eventId)) {
    throw "The message was not moved to the dedicated DLQ after $maxReceiveCount receives."
}

Remove-LocalMessage -QueueUrl $deadLetterQueue -ReceiptHandle $deadLetter.ReceiptHandle
Write-Host "Z1 DLQ test passed. SQS redrive moved the message after $maxReceiveCount receives."
} finally {
    Resume-LocalEventSourceMappings -MappingIds $suspendedMappings
}
