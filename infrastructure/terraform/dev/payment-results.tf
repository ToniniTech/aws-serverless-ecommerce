locals {
  order_payment_result_function_name = "${local.name_prefix}-order-payment-result"
  order_payment_result_artifact      = abspath("${path.root}/${var.order_payment_result_lambda_artifact}")
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
  visibility_timeout_seconds = var.order_payment_result_queue_visibility_timeout_seconds
  max_receive_count          = var.max_receive_count
  sender_service             = "events.amazonaws.com"
  sender_source_arns = [
    aws_cloudwatch_event_rule.payment_processed.arn,
    aws_cloudwatch_event_rule.payment_failed.arn
  ]
  source_account_id = data.aws_caller_identity.current.account_id
}

module "notification_payment_result_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-notification-payment-result"
  visibility_timeout_seconds = var.notification_queue_visibility_timeout_seconds
  max_receive_count          = var.max_receive_count
  sender_service             = "events.amazonaws.com"
  sender_source_arns = [
    aws_cloudwatch_event_rule.payment_processed.arn,
    aws_cloudwatch_event_rule.payment_failed.arn
  ]
  source_account_id = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_event_target" "processed_to_order" {
  rule           = aws_cloudwatch_event_rule.payment_processed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "order-payment-result"
  arn            = module.order_payment_result_queue.queue_arn
  depends_on     = [module.order_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "failed_to_order" {
  rule           = aws_cloudwatch_event_rule.payment_failed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "order-payment-result"
  arn            = module.order_payment_result_queue.queue_arn
  depends_on     = [module.order_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "processed_to_notification" {
  rule           = aws_cloudwatch_event_rule.payment_processed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-payment-result"
  arn            = module.notification_payment_result_queue.queue_arn
  depends_on     = [module.notification_payment_result_queue]
}

resource "aws_cloudwatch_event_target" "failed_to_notification" {
  rule           = aws_cloudwatch_event_rule.payment_failed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-payment-result"
  arn            = module.notification_payment_result_queue.queue_arn
  depends_on     = [module.notification_payment_result_queue]
}

resource "aws_iam_role" "order_payment_result" {
  name               = "${local.order_payment_result_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_cloudwatch_log_group" "order_payment_result" {
  name              = "/aws/lambda/${local.order_payment_result_function_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "order_payment_result" {
  statement {
    sid       = "ConsumeOnlyOrderPaymentResultQueue"
    actions   = ["sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ReceiveMessage"]
    resources = [module.order_payment_result_queue.queue_arn]
  }
  statement {
    sid       = "WriteOnlyOrderPaymentResultLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_payment_result.arn}:*"]
  }
  statement {
    sid       = "ReadOnlyOrderDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }
  statement {
    sid = "ManageOrderLambdaNetworkInterfaces"
    actions = ["ec2:AssignPrivateIpAddresses", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:UnassignPrivateIpAddresses"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "order_payment_result" {
  name   = "consume-order-payment-result"
  role   = aws_iam_role.order_payment_result.id
  policy = data.aws_iam_policy_document.order_payment_result.json
}

resource "aws_lambda_function" "order_payment_result" {
  function_name                  = local.order_payment_result_function_name
  description                    = "Idempotently applies payment results to PENDING orders in PostgreSQL."
  role                           = aws_iam_role.order_payment_result.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.order.OrderPaymentResultHandler::handleRequest"
  filename                       = local.order_payment_result_artifact
  source_code_hash               = filebase64sha256(local.order_payment_result_artifact)
  memory_size                    = 1024
  timeout                        = var.order_payment_result_lambda_timeout_seconds
  architectures                  = ["arm64"]
  reserved_concurrent_executions = 2
  vpc_config {
    subnet_ids         = aws_subnet.payment_private[*].id
    security_group_ids = [aws_security_group.order_lambda.id]
  }
  environment {
    variables = {
      DB_HOST                  = aws_db_instance.payment.address
      DB_PORT                  = tostring(aws_db_instance.payment.port)
      DB_NAME                  = var.payment_database_name
      DB_SSL_MODE              = "require"
      DB_SECRET_ARN            = aws_db_instance.payment.master_user_secret[0].secret_arn
      DB_MAX_POOL_SIZE         = tostring(var.payment_db_max_pool_size)
      DB_CONNECTION_TIMEOUT_MS = "5000"
    }
  }
  depends_on = [aws_iam_role_policy.order_payment_result, aws_cloudwatch_log_group.order_payment_result,
  aws_vpc_endpoint.secrets_manager]
}

resource "aws_lambda_event_source_mapping" "order_payment_result" {
  event_source_arn                   = module.order_payment_result_queue.queue_arn
  function_name                      = aws_lambda_function.order_payment_result.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
  scaling_config {
    maximum_concurrency = 2
  }
}

resource "aws_lambda_event_source_mapping" "notification_payment_result" {
  event_source_arn                   = module.notification_payment_result_queue.queue_arn
  function_name                      = aws_lambda_function.notification_demo.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
  scaling_config {
    maximum_concurrency = 2
  }
}
