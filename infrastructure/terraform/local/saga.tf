locals {
  saga_lambda_artifact = abspath("${path.root}/${var.saga_lambda_artifact}")
  saga_handlers = {
    reserve-stock    = "com.ecommerce.serverless.saga.SagaTaskHandlers$ReserveStock::handleRequest"
    process-payment  = "com.ecommerce.serverless.saga.SagaTaskHandlers$ProcessPayment::handleRequest"
    confirm-order    = "com.ecommerce.serverless.saga.SagaTaskHandlers$ConfirmOrder::handleRequest"
    compensate-stock = "com.ecommerce.serverless.saga.SagaTaskHandlers$CompensateStock::handleRequest"
  }
}

resource "aws_lambda_function" "saga_task" {
  for_each = local.saga_handlers

  function_name    = "${local.name_prefix}-saga-${each.key}"
  role             = aws_iam_role.local_lambda.arn
  runtime          = "java17"
  handler          = each.value
  filename         = local.saga_lambda_artifact
  source_code_hash = filebase64sha256(local.saga_lambda_artifact)
  memory_size      = 768
  timeout          = 30
  architectures    = ["x86_64"]

  environment {
    variables = local.database_environment
  }

  tags = { Phase = "Z5" }
}

data "aws_iam_policy_document" "saga_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "saga" {
  name               = "${local.name_prefix}-saga-role"
  assume_role_policy = data.aws_iam_policy_document.saga_assume_role.json
  tags               = { Phase = "Z5" }
}

data "aws_iam_policy_document" "saga_invoke" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [for function in aws_lambda_function.saga_task : function.arn]
  }
}

resource "aws_iam_role_policy" "saga_invoke" {
  name   = "invoke-saga-tasks"
  role   = aws_iam_role.saga.id
  policy = data.aws_iam_policy_document.saga_invoke.json
}

resource "aws_sfn_state_machine" "order_saga" {
  name     = "${local.name_prefix}-order-saga"
  role_arn = aws_iam_role.saga.arn
  tags     = { Phase = "Z5" }

  definition = jsonencode({
    Comment = "Isolated educational Order Saga; it does not replace the event choreography."
    StartAt = "ReserveStock"
    States = {
      ReserveStock = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.saga_task["reserve-stock"].arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "value.$" = "$.Payload" }
        ResultPath     = "$.reservation"
        Next           = "ProcessPayment"
      }
      ProcessPayment = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.saga_task["process-payment"].arn
          Payload = {
            "sagaId.$"   = "$.sagaId"
            "orderId.$"  = "$.orderId"
            "amount.$"   = "$.amount"
            "currency.$" = "$.currency"
          }
        }
        ResultSelector = { "value.$" = "$.Payload" }
        ResultPath     = "$.payment"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 1
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.workflowError", Next = "CompensateTechnicalFailure" }]
        Next  = "PaymentApproved"
      }
      PaymentApproved = {
        Type    = "Choice"
        Choices = [{ Variable = "$.payment.value.approved", BooleanEquals = true, Next = "ConfirmOrder" }]
        Default = "CompensateBusinessFailure"
      }
      ConfirmOrder = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.saga_task["confirm-order"].arn
          Payload      = { "sagaId.$" = "$.sagaId", "orderId.$" = "$.orderId" }
        }
        ResultSelector = { "value.$" = "$.Payload" }
        ResultPath     = "$.confirmation"
        End            = true
      }
      CompensateBusinessFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.saga_task["compensate-stock"].arn
          Payload = {
            "sagaId.$"  = "$.sagaId"
            "orderId.$" = "$.orderId"
            "reason.$"  = "$.payment.value.failureCode"
          }
        }
        ResultSelector = { "value.$" = "$.Payload" }
        ResultPath     = "$.compensation"
        End            = true
      }
      CompensateTechnicalFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.saga_task["compensate-stock"].arn
          Payload = {
            "sagaId.$"  = "$.sagaId"
            "orderId.$" = "$.orderId"
            "reason.$"  = "$.workflowError.Error"
          }
        }
        ResultSelector = { "value.$" = "$.Payload" }
        ResultPath     = "$.compensation"
        End            = true
      }
    }
  })
}
