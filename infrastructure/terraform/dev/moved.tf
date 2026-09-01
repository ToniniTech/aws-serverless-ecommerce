# Preserve Phase 6 state addresses for applied environments. They are harmless for a new state.
moved {
  from = aws_sqs_queue.payment_order_created
  to   = module.payment_order_created_queue.aws_sqs_queue.source
}
moved {
  from = aws_sqs_queue.payment_order_created_dlq
  to   = module.payment_order_created_queue.aws_sqs_queue.dlq
}
moved {
  from = aws_sqs_queue_redrive_allow_policy.payment_order_created_dlq
  to   = module.payment_order_created_queue.aws_sqs_queue_redrive_allow_policy.dlq
}
moved {
  from = aws_sqs_queue_policy.payment_order_created
  to   = module.payment_order_created_queue.aws_sqs_queue_policy.source
}

moved {
  from = aws_sqs_queue.notification_order_created
  to   = module.notification_order_created_queue.aws_sqs_queue.source
}
moved {
  from = aws_sqs_queue.notification_order_created_dlq
  to   = module.notification_order_created_queue.aws_sqs_queue.dlq
}
moved {
  from = aws_sqs_queue_redrive_allow_policy.notification_order_created_dlq
  to   = module.notification_order_created_queue.aws_sqs_queue_redrive_allow_policy.dlq
}
moved {
  from = aws_sqs_queue_policy.notification_order_created
  to   = module.notification_order_created_queue.aws_sqs_queue_policy.source
}

moved {
  from = aws_sqs_queue.order_payment_result
  to   = module.order_payment_result_queue.aws_sqs_queue.source
}
moved {
  from = aws_sqs_queue.order_payment_result_dlq
  to   = module.order_payment_result_queue.aws_sqs_queue.dlq
}
moved {
  from = aws_sqs_queue_redrive_allow_policy.order_payment_result_dlq
  to   = module.order_payment_result_queue.aws_sqs_queue_redrive_allow_policy.dlq
}
moved {
  from = aws_sqs_queue_policy.order_payment_result
  to   = module.order_payment_result_queue.aws_sqs_queue_policy.source
}

moved {
  from = aws_sqs_queue.notification_payment_result
  to   = module.notification_payment_result_queue.aws_sqs_queue.source
}
moved {
  from = aws_sqs_queue.notification_payment_result_dlq
  to   = module.notification_payment_result_queue.aws_sqs_queue.dlq
}
moved {
  from = aws_sqs_queue_redrive_allow_policy.notification_payment_result_dlq
  to   = module.notification_payment_result_queue.aws_sqs_queue_redrive_allow_policy.dlq
}
moved {
  from = aws_sqs_queue_policy.notification_payment_result
  to   = module.notification_payment_result_queue.aws_sqs_queue_policy.source
}

moved {
  from = aws_sns_topic.operational_alerts
  to   = module.observability.aws_sns_topic.operational_alerts
}
moved {
  from = aws_cloudwatch_metric_alarm.dlq_depth
  to   = module.observability.aws_cloudwatch_metric_alarm.dlq_depth
}
moved {
  from = aws_cloudwatch_metric_alarm.source_queue_age
  to   = module.observability.aws_cloudwatch_metric_alarm.source_queue_age
}
moved {
  from = aws_cloudwatch_metric_alarm.lambda_errors
  to   = module.observability.aws_cloudwatch_metric_alarm.lambda_errors
}
moved {
  from = aws_cloudwatch_metric_alarm.lambda_throttles
  to   = module.observability.aws_cloudwatch_metric_alarm.lambda_throttles
}
moved {
  from = aws_cloudwatch_log_metric_filter.application_errors
  to   = module.observability.aws_cloudwatch_log_metric_filter.application_errors
}
moved {
  from = aws_cloudwatch_metric_alarm.application_errors
  to   = module.observability.aws_cloudwatch_metric_alarm.application_errors
}
moved {
  from = aws_cloudwatch_metric_alarm.eventbridge_failed_invocations
  to   = module.observability.aws_cloudwatch_metric_alarm.eventbridge_failed_invocations
}
moved {
  from = aws_cloudwatch_metric_alarm.outbox_failures
  to   = module.observability.aws_cloudwatch_metric_alarm.outbox_failures
}
moved {
  from = aws_cloudwatch_metric_alarm.outbox_age
  to   = module.observability.aws_cloudwatch_metric_alarm.outbox_age
}
moved {
  from = aws_cloudwatch_metric_alarm.order_api_5xx
  to   = module.observability.aws_cloudwatch_metric_alarm.order_api_5xx
}
moved {
  from = aws_cloudwatch_dashboard.workflow
  to   = module.observability.aws_cloudwatch_dashboard.workflow
}
