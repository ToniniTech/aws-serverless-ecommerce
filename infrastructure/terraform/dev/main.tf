locals {
  name_prefix                       = "${var.project_name}-${var.environment}"
  payment_function_name             = "${local.name_prefix}-payment-order-created"
  notification_demo_function_name   = "${local.name_prefix}-notification-demo"
  payment_lambda_artifact           = abspath("${path.root}/${var.payment_lambda_artifact}")
  notification_demo_lambda_artifact = abspath("${path.root}/${var.notification_demo_lambda_artifact}")
}

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "order_events" {
  name = "${local.name_prefix}-order-events"
}

module "payment_order_created_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-payment-order-created"
  visibility_timeout_seconds = var.payment_queue_visibility_timeout_seconds
  max_receive_count          = var.max_receive_count
  sender_service             = "sns.amazonaws.com"
  sender_source_arns         = [aws_sns_topic.order_events.arn]
  source_account_id          = data.aws_caller_identity.current.account_id
}

module "notification_order_created_queue" {
  source = "../modules/sqs-redrive-flow"

  name                       = "${local.name_prefix}-notification-order-created"
  visibility_timeout_seconds = var.notification_queue_visibility_timeout_seconds
  max_receive_count          = var.max_receive_count
  sender_service             = "sns.amazonaws.com"
  sender_source_arns         = [aws_sns_topic.order_events.arn]
  source_account_id          = data.aws_caller_identity.current.account_id
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

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "payment_consumer" {
  name               = "${local.payment_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "notification_demo" {
  name               = "${local.notification_demo_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_cloudwatch_log_group" "payment_consumer" {
  name              = "/aws/lambda/${local.payment_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "notification_demo" {
  name              = "/aws/lambda/${local.notification_demo_function_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "payment_consumer" {
  statement {
    sid = "ConsumeOnlyPaymentOrderCreatedQueue"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage"
    ]
    resources = [module.payment_order_created_queue.queue_arn]
  }

  statement {
    sid       = "WriteOnlyPaymentFunctionLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.payment_consumer.arn}:*"]
  }

  statement {
    sid       = "ReadOnlyPaymentDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }

  statement {
    sid = "ManagePaymentLambdaNetworkInterfaces"
    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "notification_demo" {
  statement {
    sid = "ConsumeOnlyNotificationOrderCreatedQueue"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage"
    ]
    resources = [
      module.notification_order_created_queue.queue_arn,
      module.notification_payment_result_queue.queue_arn
    ]
  }

  statement {
    sid       = "WriteOnlyNotificationFunctionLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notification_demo.arn}:*"]
  }

  statement {
    sid       = "ReadOnlyNotificationDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }

  statement {
    sid = "ManageNotificationLambdaNetworkInterfaces"
    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "payment_consumer" {
  name   = "consume-payment-order-created"
  role   = aws_iam_role.payment_consumer.id
  policy = data.aws_iam_policy_document.payment_consumer.json
}

resource "aws_iam_role_policy" "notification_demo" {
  name   = "consume-notification-order-created"
  role   = aws_iam_role.notification_demo.id
  policy = data.aws_iam_policy_document.notification_demo.json
}

resource "aws_lambda_function" "payment_order_created" {
  function_name                  = local.payment_function_name
  description                    = "Durable idempotent OrderCreated Payment consumer backed by PostgreSQL."
  role                           = aws_iam_role.payment_consumer.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.payment.PaymentOrderCreatedHandler::handleRequest"
  filename                       = local.payment_lambda_artifact
  source_code_hash               = filebase64sha256(local.payment_lambda_artifact)
  memory_size                    = 1024
  timeout                        = var.payment_lambda_timeout_seconds
  architectures                  = ["arm64"]
  reserved_concurrent_executions = 2

  vpc_config {
    subnet_ids         = aws_subnet.payment_private[*].id
    security_group_ids = [aws_security_group.payment_lambda.id]
  }

  environment {
    variables = {
      DB_HOST                          = aws_db_instance.payment.address
      DB_PORT                          = tostring(aws_db_instance.payment.port)
      DB_NAME                          = var.payment_database_name
      DB_SSL_MODE                      = "require"
      DB_SECRET_ARN                    = aws_db_instance.payment.master_user_secret[0].secret_arn
      DB_MAX_POOL_SIZE                 = tostring(var.payment_db_max_pool_size)
      DB_CONNECTION_TIMEOUT_MS         = "5000"
      PAYMENT_PROCESSING_LEASE_SECONDS = "60"
    }
  }

  depends_on = [
    aws_iam_role_policy.payment_consumer,
    aws_cloudwatch_log_group.payment_consumer,
    aws_vpc_endpoint.secrets_manager
  ]
}

resource "aws_lambda_function" "notification_demo" {
  function_name    = local.notification_demo_function_name
  description      = "Durable idempotent Notification consumer backed by PostgreSQL."
  role             = aws_iam_role.notification_demo.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.notification.NotificationDemoHandler::handleRequest"
  filename         = local.notification_demo_lambda_artifact
  source_code_hash = filebase64sha256(local.notification_demo_lambda_artifact)
  memory_size      = 512
  timeout          = var.notification_lambda_timeout_seconds
  architectures    = ["arm64"]

  vpc_config {
    subnet_ids         = aws_subnet.payment_private[*].id
    security_group_ids = [aws_security_group.notification_lambda.id]
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

  depends_on = [
    aws_iam_role_policy.notification_demo,
    aws_cloudwatch_log_group.notification_demo,
    aws_vpc_endpoint.secrets_manager
  ]
}

resource "aws_lambda_event_source_mapping" "payment_order_created" {
  event_source_arn                   = module.payment_order_created_queue.queue_arn
  function_name                      = aws_lambda_function.payment_order_created.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true

  scaling_config {
    maximum_concurrency = 2
  }
}

resource "aws_lambda_event_source_mapping" "notification_order_created" {
  event_source_arn                   = module.notification_order_created_queue.queue_arn
  function_name                      = aws_lambda_function.notification_demo.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true

  scaling_config {
    maximum_concurrency = 2
  }
}
