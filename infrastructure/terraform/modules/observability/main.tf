data "aws_partition" "current" {}

resource "aws_sns_topic" "operational_alerts" {
  name = "${var.name_prefix}-operational-alerts"
}

data "aws_iam_policy_document" "operational_alerts" {
  statement {
    sid       = "AllowAccountAdministration"
    actions   = ["sns:DeleteTopic", "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic", "sns:Publish", "sns:SetTopicAttributes", "sns:Subscribe"]
    resources = [aws_sns_topic.operational_alerts.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.source_account_id}:root"]
    }
  }

  statement {
    sid       = "AllowOnlyCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.operational_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.source_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "operational_alerts" {
  arn    = aws_sns_topic.operational_alerts.arn
  policy = data.aws_iam_policy_document.operational_alerts.json
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  for_each = var.dlqs

  alarm_name          = "${var.name_prefix}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages reached ${each.key} DLQ and require diagnosis before redrive."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  ok_actions          = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { QueueName = each.value }
}

resource "aws_cloudwatch_metric_alarm" "source_queue_age" {
  for_each = var.source_queues

  alarm_name          = "${var.name_prefix}-${each.key}-oldest-message"
  alarm_description   = "The oldest ${each.key} message is delayed beyond the environment threshold."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_evaluation_periods
  threshold           = var.queue_age_alarm_seconds
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  ok_actions          = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { QueueName = each.value }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambdas

  alarm_name          = "${var.name_prefix}-${each.key}-lambda-errors"
  alarm_description   = "${each.key} returned an unhandled Lambda error."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { FunctionName = each.value }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.lambdas

  alarm_name          = "${var.name_prefix}-${each.key}-lambda-throttles"
  alarm_description   = "${each.key} was throttled; inspect concurrency and downstream capacity."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { FunctionName = each.value }
}

resource "aws_cloudwatch_log_metric_filter" "application_errors" {
  for_each = var.application_log_groups

  name           = "${var.name_prefix}-${each.key}-application-errors"
  log_group_name = each.value
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "ApplicationErrors-${each.key}"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "application_errors" {
  for_each = var.application_log_groups

  alarm_name          = "${var.name_prefix}-${each.key}-application-errors"
  alarm_description   = "${each.key} logged an application error, including SQS partial-batch failures."
  namespace           = var.metric_namespace
  metric_name         = "ApplicationErrors-${each.key}"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  depends_on          = [aws_cloudwatch_log_metric_filter.application_errors]
}

resource "aws_cloudwatch_metric_alarm" "eventbridge_failed_invocations" {
  for_each = var.eventbridge_rules

  alarm_name          = "${var.name_prefix}-${each.key}-eventbridge-failed-invocations"
  alarm_description   = "EventBridge could not invoke a target for ${each.key}."
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  dimensions = merge(
    { RuleName = each.value.rule_name },
    each.value.event_bus_name == null ? {} : { EventBusName = each.value.event_bus_name }
  )
}

resource "aws_cloudwatch_metric_alarm" "outbox_failures" {
  for_each = var.outbox_publishers

  alarm_name          = "${var.name_prefix}-${each.key}-publish-failures"
  alarm_description   = "${each.key} failed to publish one or more claimed rows."
  namespace           = var.metric_namespace
  metric_name         = "OutboxFailed"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { Publisher = each.key }
}

resource "aws_cloudwatch_metric_alarm" "outbox_age" {
  for_each = var.outbox_publishers

  alarm_name          = "${var.name_prefix}-${each.key}-oldest-outstanding"
  alarm_description   = "${each.key} has an unpublished row older than the expected schedule delay."
  namespace           = var.metric_namespace
  metric_name         = "OutboxOldestOutstandingAgeSeconds"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_evaluation_periods
  threshold           = var.outbox_age_alarm_seconds
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  ok_actions          = [aws_sns_topic.operational_alerts.arn]
  dimensions          = { Publisher = each.key }
}

resource "aws_cloudwatch_metric_alarm" "order_api_5xx" {
  alarm_name          = "${var.name_prefix}-order-api-5xx"
  alarm_description   = "The Order HTTP API returned a server error."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  dimensions = {
    ApiId = var.api_id
    Stage = var.api_stage
  }
}

resource "aws_cloudwatch_dashboard" "workflow" {
  dashboard_name = "${var.name_prefix}-workflow"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title = "Source queue age", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [for key, queue_name in var.source_queues :
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", queue_name, { label = key }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title = "DLQ visible messages", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [for key, queue_name in var.dlqs :
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", queue_name, { label = key }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title = "Lambda errors and throttles", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = concat(
            [for key, function_name in var.lambdas : ["AWS/Lambda", "Errors", "FunctionName", function_name, { label = "${key} errors" }]],
            [for key, function_name in var.lambdas : ["AWS/Lambda", "Throttles", "FunctionName", function_name, { label = "${key} throttles" }]]
          )
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title = "Lambda duration p95", region = var.aws_region, view = "timeSeries", period = 60, stat = "p95",
          metrics = [for key, function_name in var.lambdas :
            ["AWS/Lambda", "Duration", "FunctionName", function_name, { label = key }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6,
        properties = {
          title = "Outbox publication", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = concat(
            [for publisher in var.outbox_publishers : [var.metric_namespace, "OutboxPublished", "Publisher", publisher, { label = "${publisher} published" }]],
            [for publisher in var.outbox_publishers : [var.metric_namespace, "OutboxFailed", "Publisher", publisher, { label = "${publisher} failed" }]]
          )
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6,
        properties = {
          title = "Oldest outstanding Outbox row", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [for publisher in var.outbox_publishers :
            [var.metric_namespace, "OutboxOldestOutstandingAgeSeconds", "Publisher", publisher, { label = publisher }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 18, width = 12, height = 6,
        properties = {
          title = "RDS CPU and connections", region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_identifier, { label = "CPU %", yAxis = "left" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_identifier, { label = "connections", yAxis = "right" }]
          ]
        }
      },
      {
        type = "alarm", x = 12, y = 18, width = 12, height = 6,
        properties = {
          title = "Workflow alarms",
          alarms = concat(
            [for alarm in aws_cloudwatch_metric_alarm.dlq_depth : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.source_queue_age : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.outbox_age : alarm.arn],
            [aws_cloudwatch_metric_alarm.order_api_5xx.arn]
          )
        }
      }
    ]
  })
}
