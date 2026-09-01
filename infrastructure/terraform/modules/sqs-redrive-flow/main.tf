resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "source" {
  name                       = "${var.name}-queue"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.source.arn]
  })
}

data "aws_iam_policy_document" "source" {
  statement {
    sid       = "AllowOnlyDeclaredAwsSender"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.source.arn]

    principals {
      type        = "Service"
      identifiers = [var.sender_service]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = var.sender_source_arns
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.source_account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "source" {
  queue_url = aws_sqs_queue.source.id
  policy    = data.aws_iam_policy_document.source.json
}
