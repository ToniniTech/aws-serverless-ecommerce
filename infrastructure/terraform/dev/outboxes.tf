locals {
  payment_outbox_function_name = "${local.name_prefix}-payment-outbox-publisher"
  order_outbox_function_name   = "${local.name_prefix}-order-outbox-publisher"
}

resource "aws_cloudwatch_log_group" "payment_outbox" {
  name              = "/aws/lambda/${local.payment_outbox_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "order_outbox" {
  name              = "/aws/lambda/${local.order_outbox_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "payment_outbox" {
  name               = "${local.payment_outbox_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "order_outbox" {
  name               = "${local.order_outbox_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "payment_outbox" {
  statement {
    sid       = "PublishOnlyPaymentEventBus"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.payment_events.arn]
  }
  statement {
    sid       = "ReadOnlyPaymentDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "WriteOnlyPaymentOutboxLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.payment_outbox.arn}:*"]
  }
  statement {
    sid = "ManagePaymentOutboxNetworkInterfaces"
    actions = ["ec2:AssignPrivateIpAddresses", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:UnassignPrivateIpAddresses"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "order_outbox" {
  statement {
    sid       = "PublishOnlyOrderEventsTopic"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.order_events.arn]
  }
  statement {
    sid       = "ReadOnlyOrderDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "WriteOnlyOrderOutboxLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_outbox.arn}:*"]
  }
  statement {
    sid = "ManageOrderOutboxNetworkInterfaces"
    actions = ["ec2:AssignPrivateIpAddresses", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:UnassignPrivateIpAddresses"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "payment_outbox" {
  name   = "publish-payment-outbox"
  role   = aws_iam_role.payment_outbox.id
  policy = data.aws_iam_policy_document.payment_outbox.json
}

resource "aws_iam_role_policy" "order_outbox" {
  name   = "publish-order-outbox"
  role   = aws_iam_role.order_outbox.id
  policy = data.aws_iam_policy_document.order_outbox.json
}

resource "aws_lambda_function" "payment_outbox" {
  function_name                  = local.payment_outbox_function_name
  role                           = aws_iam_role.payment_outbox.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.payment.PaymentOutboxPublisherHandler::handleRequest"
  filename                       = local.payment_lambda_artifact
  source_code_hash               = filebase64sha256(local.payment_lambda_artifact)
  memory_size                    = 1024
  timeout                        = 30
  architectures                  = ["arm64"]
  reserved_concurrent_executions = 2
  vpc_config {
    subnet_ids         = aws_subnet.payment_private[*].id
    security_group_ids = [aws_security_group.payment_lambda.id]
  }
  environment {
    variables = {
      DB_HOST                    = aws_db_instance.payment.address
      DB_PORT                    = tostring(aws_db_instance.payment.port)
      DB_NAME                    = var.payment_database_name
      DB_SSL_MODE                = "require"
      DB_SECRET_ARN              = aws_db_instance.payment.master_user_secret[0].secret_arn
      DB_MAX_POOL_SIZE           = tostring(var.payment_db_max_pool_size)
      DB_CONNECTION_TIMEOUT_MS   = "5000"
      PAYMENT_EVENT_BUS_NAME     = aws_cloudwatch_event_bus.payment_events.name
      OUTBOX_BATCH_SIZE          = tostring(var.outbox_batch_size)
      OUTBOX_CLAIM_LEASE_SECONDS = tostring(var.outbox_claim_lease_seconds)
      METRIC_NAMESPACE           = local.observability_metric_namespace
    }
  }
  depends_on = [aws_iam_role_policy.payment_outbox, aws_cloudwatch_log_group.payment_outbox,
  aws_vpc_endpoint.secrets_manager, aws_vpc_endpoint.eventbridge]
}

resource "aws_lambda_function" "order_outbox" {
  function_name                  = local.order_outbox_function_name
  role                           = aws_iam_role.order_outbox.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.order.OrderOutboxPublisherHandler::handleRequest"
  filename                       = local.order_payment_result_artifact
  source_code_hash               = filebase64sha256(local.order_payment_result_artifact)
  memory_size                    = 1024
  timeout                        = 30
  architectures                  = ["arm64"]
  reserved_concurrent_executions = 2
  vpc_config {
    subnet_ids         = aws_subnet.payment_private[*].id
    security_group_ids = [aws_security_group.order_lambda.id]
  }
  environment {
    variables = {
      DB_HOST                    = aws_db_instance.payment.address
      DB_PORT                    = tostring(aws_db_instance.payment.port)
      DB_NAME                    = var.payment_database_name
      DB_SSL_MODE                = "require"
      DB_SECRET_ARN              = aws_db_instance.payment.master_user_secret[0].secret_arn
      DB_MAX_POOL_SIZE           = tostring(var.payment_db_max_pool_size)
      DB_CONNECTION_TIMEOUT_MS   = "5000"
      ORDER_EVENTS_TOPIC_ARN     = aws_sns_topic.order_events.arn
      OUTBOX_BATCH_SIZE          = tostring(var.outbox_batch_size)
      OUTBOX_CLAIM_LEASE_SECONDS = tostring(var.outbox_claim_lease_seconds)
      METRIC_NAMESPACE           = local.observability_metric_namespace
    }
  }
  depends_on = [aws_iam_role_policy.order_outbox, aws_cloudwatch_log_group.order_outbox,
  aws_vpc_endpoint.secrets_manager, aws_vpc_endpoint.sns]
}

resource "aws_cloudwatch_event_rule" "payment_outbox_schedule" {
  name                = "${local.name_prefix}-payment-outbox-schedule"
  description         = "Poll the Payment Outbox in bounded batches."
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_rule" "order_outbox_schedule" {
  name                = "${local.name_prefix}-order-outbox-schedule"
  description         = "Poll the Order Outbox in bounded batches."
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "payment_outbox_schedule" {
  rule      = aws_cloudwatch_event_rule.payment_outbox_schedule.name
  target_id = "payment-outbox-publisher"
  arn       = aws_lambda_function.payment_outbox.arn
}

resource "aws_cloudwatch_event_target" "order_outbox_schedule" {
  rule      = aws_cloudwatch_event_rule.order_outbox_schedule.name
  target_id = "order-outbox-publisher"
  arn       = aws_lambda_function.order_outbox.arn
}

resource "aws_lambda_permission" "payment_outbox_schedule" {
  statement_id   = "AllowEventBridgeSchedule"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.payment_outbox.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.payment_outbox_schedule.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_lambda_permission" "order_outbox_schedule" {
  statement_id   = "AllowEventBridgeSchedule"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.order_outbox.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.order_outbox_schedule.arn
  source_account = data.aws_caller_identity.current.account_id
}
