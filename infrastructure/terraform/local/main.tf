locals {
  name_prefix = "${var.project_name}-local"
}

resource "aws_sns_topic" "order_events" {
  name = "${local.name_prefix}-order-events"
}

module "payment_order_created_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-payment-order-created"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 0
  max_receive_count          = var.max_receive_count
  sender_service             = "sns.amazonaws.com"
  sender_source_arns         = [aws_sns_topic.order_events.arn]
  source_account_id          = var.local_account_id
}

module "notification_order_created_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-notification-order-created"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 0
  max_receive_count          = var.max_receive_count
  sender_service             = "sns.amazonaws.com"
  sender_source_arns         = [aws_sns_topic.order_events.arn]
  source_account_id          = var.local_account_id
}

resource "aws_sns_topic_subscription" "payment_order_created" {
  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = module.payment_order_created_queue.queue_arn
  raw_message_delivery = true

  depends_on = [module.payment_order_created_queue]
}

resource "aws_sns_topic_subscription" "notification_order_created" {
  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = module.notification_order_created_queue.queue_arn
  raw_message_delivery = true

  depends_on = [module.notification_order_created_queue]
}

resource "aws_cloudwatch_event_bus" "payment_events" {
  name = "${local.name_prefix}-payment-events"
}

resource "aws_cloudwatch_event_rule" "payment_processed" {
  name           = "${local.name_prefix}-payment-processed"
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  event_pattern = jsonencode({
    source      = ["com.ecommerce.payment"]
    detail-type = ["PaymentProcessed"]
  })
}

resource "aws_cloudwatch_event_rule" "payment_failed" {
  name           = "${local.name_prefix}-payment-failed"
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  event_pattern = jsonencode({
    source      = ["com.ecommerce.payment"]
    detail-type = ["PaymentFailed"]
  })
}

module "order_payment_result_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-order-payment-result"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 0
  max_receive_count          = var.max_receive_count
  sender_service             = "events.amazonaws.com"
  sender_source_arns = [
    aws_cloudwatch_event_rule.payment_processed.arn,
    aws_cloudwatch_event_rule.payment_failed.arn
  ]
  source_account_id = var.local_account_id
}

module "notification_payment_result_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-notification-payment-result"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 0
  max_receive_count          = var.max_receive_count
  sender_service             = "events.amazonaws.com"
  sender_source_arns = [
    aws_cloudwatch_event_rule.payment_processed.arn,
    aws_cloudwatch_event_rule.payment_failed.arn
  ]
  source_account_id = var.local_account_id
}

resource "aws_cloudwatch_event_target" "processed_to_order" {
  rule           = aws_cloudwatch_event_rule.payment_processed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "order-payment-result"
  arn            = module.order_payment_result_queue.queue_arn

  depends_on = [module.order_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "failed_to_order" {
  rule           = aws_cloudwatch_event_rule.payment_failed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "order-payment-result"
  arn            = module.order_payment_result_queue.queue_arn

  depends_on = [module.order_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "processed_to_notification" {
  rule           = aws_cloudwatch_event_rule.payment_processed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-payment-result"
  arn            = module.notification_payment_result_queue.queue_arn

  depends_on = [module.notification_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "failed_to_notification" {
  rule           = aws_cloudwatch_event_rule.payment_failed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-payment-result"
  arn            = module.notification_payment_result_queue.queue_arn

  depends_on = [module.notification_payment_result_queue]
}
