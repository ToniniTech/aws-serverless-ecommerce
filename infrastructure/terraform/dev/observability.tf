locals {
  observability_metric_namespace = "${var.project_name}/${var.environment}"
}

module "observability" {
  source = "../modules/observability"

  name_prefix       = local.name_prefix
  aws_region        = var.aws_region
  metric_namespace  = local.observability_metric_namespace
  source_account_id = data.aws_caller_identity.current.account_id

  source_queues = {
    payment-order-created       = module.payment_order_created_queue.queue_name
    notification-order-created  = module.notification_order_created_queue.queue_name
    order-payment-result        = module.order_payment_result_queue.queue_name
    notification-payment-result = module.notification_payment_result_queue.queue_name
  }

  dlqs = {
    payment-order-created       = module.payment_order_created_queue.dlq_name
    notification-order-created  = module.notification_order_created_queue.dlq_name
    order-payment-result        = module.order_payment_result_queue.dlq_name
    notification-payment-result = module.notification_payment_result_queue.dlq_name
  }

  lambdas = {
    payment-consumer  = aws_lambda_function.payment_order_created.function_name
    notification-demo = aws_lambda_function.notification_demo.function_name
    order-result      = aws_lambda_function.order_payment_result.function_name
    order-command     = aws_lambda_function.order_command.function_name
    order-query       = aws_lambda_function.order_query.function_name
    order-outbox      = aws_lambda_function.order_outbox.function_name
    payment-outbox    = aws_lambda_function.payment_outbox.function_name
  }

  application_log_groups = {
    payment-consumer  = aws_cloudwatch_log_group.payment_consumer.name
    notification-demo = aws_cloudwatch_log_group.notification_demo.name
    order-result      = aws_cloudwatch_log_group.order_payment_result.name
    order-command     = aws_cloudwatch_log_group.order_command.name
    order-query       = aws_cloudwatch_log_group.order_query.name
  }

  eventbridge_rules = {
    payment-processed = {
      rule_name      = aws_cloudwatch_event_rule.payment_processed.name
      event_bus_name = aws_cloudwatch_event_bus.payment_events.name
    }
    payment-failed = {
      rule_name      = aws_cloudwatch_event_rule.payment_failed.name
      event_bus_name = aws_cloudwatch_event_bus.payment_events.name
    }
    payment-outbox-schedule = {
      rule_name = aws_cloudwatch_event_rule.payment_outbox_schedule.name
    }
    order-outbox-schedule = {
      rule_name = aws_cloudwatch_event_rule.order_outbox_schedule.name
    }
  }

  outbox_publishers        = ["order-outbox", "payment-outbox"]
  api_id                   = aws_apigatewayv2_api.orders.id
  api_stage                = aws_apigatewayv2_stage.dev.name
  db_instance_identifier   = aws_db_instance.payment.identifier
  queue_age_alarm_seconds  = var.queue_age_alarm_seconds
  outbox_age_alarm_seconds = var.outbox_age_alarm_seconds
  alarm_evaluation_periods = var.alarm_evaluation_periods
}
