locals {
  payment_lambda_artifact      = abspath("${path.root}/${var.payment_lambda_artifact}")
  order_lambda_artifact        = abspath("${path.root}/${var.order_lambda_artifact}")
  notification_lambda_artifact = abspath("${path.root}/${var.notification_lambda_artifact}")

  database_environment = {
    DB_URL                   = "jdbc:postgresql://payment-postgres:5432/payments?sslmode=disable"
    DB_USERNAME              = "payment_local"
    DB_PASSWORD              = "payment_local"
    DB_MAX_POOL_SIZE         = "2"
    DB_CONNECTION_TIMEOUT_MS = "5000"
  }
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

resource "aws_iam_role" "local_lambda" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_lambda_function" "order_command" {
  function_name    = "${local.name_prefix}-order-command"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.order.OrderCreateHandler::handleRequest"
  filename         = local.order_lambda_artifact
  source_code_hash = filebase64sha256(local.order_lambda_artifact)
  memory_size      = 1024
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = merge(local.database_environment, {
      PRODUCT_ADAPTER_MODE = "SIMULATED"
      ORDER_CURRENCY       = "CLP"
    })
  }
}

resource "aws_lambda_function" "order_query" {
  function_name    = "${local.name_prefix}-order-query"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.order.OrderGetHandler::handleRequest"
  filename         = local.order_lambda_artifact
  source_code_hash = filebase64sha256(local.order_lambda_artifact)
  memory_size      = 768
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = local.database_environment
  }
}

resource "aws_lambda_function" "order_outbox" {
  function_name    = "${local.name_prefix}-order-outbox"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.order.OrderOutboxPublisherHandler::handleRequest"
  filename         = local.order_lambda_artifact
  source_code_hash = filebase64sha256(local.order_lambda_artifact)
  memory_size      = 1024
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = merge(local.database_environment, {
      ORDER_EVENTS_TOPIC_ARN     = aws_sns_topic.order_events.arn
      OUTBOX_BATCH_SIZE          = "10"
      OUTBOX_CLAIM_LEASE_SECONDS = "120"
      METRIC_NAMESPACE           = "serverless-ecommerce/local"
    })
  }
}

resource "aws_lambda_function" "payment_order_created" {
  function_name    = "${local.name_prefix}-payment-order-created"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.payment.PaymentOrderCreatedHandler::handleRequest"
  filename         = local.payment_lambda_artifact
  source_code_hash = filebase64sha256(local.payment_lambda_artifact)
  memory_size      = 1024
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = merge(local.database_environment, {
      PAYMENT_PROCESSING_LEASE_SECONDS = "60"
    })
  }
}

resource "aws_lambda_function" "payment_outbox" {
  function_name    = "${local.name_prefix}-payment-outbox"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.payment.PaymentOutboxPublisherHandler::handleRequest"
  filename         = local.payment_lambda_artifact
  source_code_hash = filebase64sha256(local.payment_lambda_artifact)
  memory_size      = 1024
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = merge(local.database_environment, {
      PAYMENT_EVENT_BUS_NAME     = aws_cloudwatch_event_bus.payment_events.name
      OUTBOX_BATCH_SIZE          = "10"
      OUTBOX_CLAIM_LEASE_SECONDS = "120"
      METRIC_NAMESPACE           = "serverless-ecommerce/local"
    })
  }
}

resource "aws_lambda_function" "order_payment_result" {
  function_name    = "${local.name_prefix}-order-payment-result"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.order.OrderPaymentResultHandler::handleRequest"
  filename         = local.order_lambda_artifact
  source_code_hash = filebase64sha256(local.order_lambda_artifact)
  memory_size      = 1024
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = local.database_environment
  }
}

resource "aws_lambda_function" "notification_demo" {
  function_name    = "${local.name_prefix}-notification-demo"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = "com.ecommerce.serverless.notification.NotificationDemoHandler::handleRequest"
  filename         = local.notification_lambda_artifact
  source_code_hash = filebase64sha256(local.notification_lambda_artifact)
  memory_size      = 512
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = local.database_environment
  }
}

resource "aws_lambda_event_source_mapping" "payment_order_created" {
  event_source_arn        = module.payment_order_created_queue.queue_arn
  function_name           = aws_lambda_function.payment_order_created.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
}

resource "aws_lambda_event_source_mapping" "notification_order_created" {
  event_source_arn        = module.notification_order_created_queue.queue_arn
  function_name           = aws_lambda_function.notification_demo.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
}

resource "aws_lambda_event_source_mapping" "order_payment_result" {
  event_source_arn        = module.order_payment_result_queue.queue_arn
  function_name           = aws_lambda_function.order_payment_result.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
}

resource "aws_lambda_event_source_mapping" "notification_payment_result" {
  event_source_arn        = module.notification_payment_result_queue.queue_arn
  function_name           = aws_lambda_function.notification_demo.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = true
}
