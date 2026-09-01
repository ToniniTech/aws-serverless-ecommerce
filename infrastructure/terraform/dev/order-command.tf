locals {
  order_command_function_name = "${local.name_prefix}-order-command"
  order_query_function_name   = "${local.name_prefix}-order-query"
}

resource "aws_cloudwatch_log_group" "order_command" {
  name              = "/aws/lambda/${local.order_command_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "order_api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-orders"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "order_query" {
  name              = "/aws/lambda/${local.order_query_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "order_command" {
  name               = "${local.order_command_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "order_command" {
  statement {
    sid       = "ReadOnlyOrderDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "WriteOnlyOrderCommandLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_command.arn}:*"]
  }
  statement {
    sid = "ManageOrderCommandNetworkInterfaces"
    actions = ["ec2:AssignPrivateIpAddresses", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:UnassignPrivateIpAddresses"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "order_command" {
  name   = "run-order-command"
  role   = aws_iam_role.order_command.id
  policy = data.aws_iam_policy_document.order_command.json
}

resource "aws_iam_role" "order_query" {
  name               = "${local.order_query_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "order_query" {
  statement {
    sid       = "ReadOnlyOrderDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "WriteOnlyOrderQueryLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_query.arn}:*"]
  }
  statement {
    sid = "ManageOrderQueryNetworkInterfaces"
    actions = ["ec2:AssignPrivateIpAddresses", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:UnassignPrivateIpAddresses"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "order_query" {
  name   = "run-order-query"
  role   = aws_iam_role.order_query.id
  policy = data.aws_iam_policy_document.order_query.json
}

resource "aws_lambda_function" "order_command" {
  function_name                  = local.order_command_function_name
  description                    = "Selected synchronous Product boundary plus atomic Order and Order Outbox persistence."
  role                           = aws_iam_role.order_command.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.order.OrderCreateHandler::handleRequest"
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
    variables = merge({
      DB_HOST                    = aws_db_instance.payment.address
      DB_PORT                    = tostring(aws_db_instance.payment.port)
      DB_NAME                    = var.payment_database_name
      DB_SSL_MODE                = "require"
      DB_SECRET_ARN              = aws_db_instance.payment.master_user_secret[0].secret_arn
      DB_MAX_POOL_SIZE           = tostring(var.payment_db_max_pool_size)
      DB_CONNECTION_TIMEOUT_MS   = "5000"
      PRODUCT_ADAPTER_MODE       = var.product_adapter_mode
      PRODUCT_SERVICE_TIMEOUT_MS = "5000"
      ORDER_CURRENCY             = "CLP"
      }, var.product_adapter_mode == "HTTP" ? {
      PRODUCT_SERVICE_BASE_URL = var.product_service_base_url
    } : {})
  }
  depends_on = [aws_iam_role_policy.order_command, aws_cloudwatch_log_group.order_command,
  aws_vpc_endpoint.secrets_manager]
}

resource "aws_lambda_function" "order_query" {
  function_name                  = local.order_query_function_name
  description                    = "Read-only Order status and item projection for deployment verification."
  role                           = aws_iam_role.order_query.arn
  runtime                        = "java17"
  handler                        = "com.ecommerce.serverless.order.OrderGetHandler::handleRequest"
  filename                       = local.order_payment_result_artifact
  source_code_hash               = filebase64sha256(local.order_payment_result_artifact)
  memory_size                    = 768
  timeout                        = 15
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
  depends_on = [aws_iam_role_policy.order_query, aws_cloudwatch_log_group.order_query,
  aws_vpc_endpoint.secrets_manager]
}

resource "aws_apigatewayv2_api" "orders" {
  name          = "${local.name_prefix}-orders"
  protocol_type = "HTTP"
}

locals {
  order_create_invoke_arn = "${aws_apigatewayv2_api.orders.execution_arn}/*/POST/orders"
  order_query_invoke_arn  = "${aws_apigatewayv2_api.orders.execution_arn}/*/GET/orders/*"
}

resource "aws_apigatewayv2_integration" "order_command" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order_command.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "create_order" {
  api_id             = aws_apigatewayv2_api.orders.id
  route_key          = "POST /orders"
  authorization_type = var.order_api_authorization_type
  target             = "integrations/${aws_apigatewayv2_integration.order_command.id}"
}

resource "aws_apigatewayv2_integration" "order_query" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order_query.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 15000
}

resource "aws_apigatewayv2_route" "get_order" {
  api_id             = aws_apigatewayv2_api.orders.id
  route_key          = "GET /orders/{orderId}"
  authorization_type = var.order_api_authorization_type
  target             = "integrations/${aws_apigatewayv2_integration.order_query.id}"
}

resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.order_api_throttling_burst_limit
    throttling_rate_limit    = var.order_api_throttling_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.order_api_access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
      sourceIp         = "$context.identity.sourceIp"
      userArn          = "$context.identity.userArn"
    })
  }
}

resource "aws_lambda_permission" "order_api" {
  statement_id   = "AllowHttpApi"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.order_command.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = local.order_create_invoke_arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_lambda_permission" "order_query_api" {
  statement_id   = "AllowOrderQueryHttpApi"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.order_query.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = local.order_query_invoke_arn
  source_account = data.aws_caller_identity.current.account_id
}
