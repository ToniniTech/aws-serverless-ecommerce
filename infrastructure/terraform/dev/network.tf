data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "payment" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-payment-vpc"
  }
}

resource "aws_subnet" "payment_private" {
  count = 2

  vpc_id                  = aws_vpc.payment.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-payment-private-${count.index + 1}"
  }
}

resource "aws_route_table" "payment_private" {
  vpc_id = aws_vpc.payment.id

  tags = {
    Name = "${local.name_prefix}-payment-private"
  }
}

resource "aws_route_table_association" "payment_private" {
  count = 2

  subnet_id      = aws_subnet.payment_private[count.index].id
  route_table_id = aws_route_table.payment_private.id
}

resource "aws_security_group" "payment_lambda" {
  name        = "${local.name_prefix}-payment-lambda"
  description = "Egress for Payment consumer and Outbox publisher to their private dependencies."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "order_lambda" {
  name        = "${local.name_prefix}-order-lambda"
  description = "Egress for Order handlers to PostgreSQL, Product, Secrets Manager, and SNS."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "notification_lambda" {
  name        = "${local.name_prefix}-notification-lambda"
  description = "Egress for Notification consumers to PostgreSQL and Secrets Manager."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "payment_database" {
  name        = "${local.name_prefix}-payment-database"
  description = "PostgreSQL ingress only from Payment, Order, and Notification Lambda security groups."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "secrets_manager_endpoint" {
  name        = "${local.name_prefix}-secrets-manager-endpoint"
  description = "HTTPS ingress only from application Lambda security groups that read the RDS secret."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "eventbridge_endpoint" {
  name        = "${local.name_prefix}-eventbridge-endpoint"
  description = "HTTPS ingress only from Payment Lambda."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_security_group" "sns_endpoint" {
  name        = "${local.name_prefix}-sns-endpoint"
  description = "HTTPS ingress from the Order Outbox publisher."
  vpc_id      = aws_vpc.payment.id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_payment_lambda" {
  security_group_id            = aws_security_group.payment_database.id
  referenced_security_group_id = aws_security_group.payment_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "payment_lambda_to_database" {
  security_group_id            = aws_security_group.payment_lambda.id
  referenced_security_group_id = aws_security_group.payment_database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "database_from_order_lambda" {
  security_group_id            = aws_security_group.payment_database.id
  referenced_security_group_id = aws_security_group.order_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "order_lambda_to_database" {
  security_group_id            = aws_security_group.order_lambda.id
  referenced_security_group_id = aws_security_group.payment_database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "database_from_notification_lambda" {
  security_group_id            = aws_security_group.payment_database.id
  referenced_security_group_id = aws_security_group.notification_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "notification_lambda_to_database" {
  security_group_id            = aws_security_group.notification_lambda.id
  referenced_security_group_id = aws_security_group.payment_database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "secrets_endpoint_from_payment_lambda" {
  security_group_id            = aws_security_group.secrets_manager_endpoint.id
  referenced_security_group_id = aws_security_group.payment_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "payment_lambda_to_secrets_endpoint" {
  security_group_id            = aws_security_group.payment_lambda.id
  referenced_security_group_id = aws_security_group.secrets_manager_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "secrets_endpoint_from_order_lambda" {
  security_group_id            = aws_security_group.secrets_manager_endpoint.id
  referenced_security_group_id = aws_security_group.order_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "order_lambda_to_secrets_endpoint" {
  security_group_id            = aws_security_group.order_lambda.id
  referenced_security_group_id = aws_security_group.secrets_manager_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "secrets_endpoint_from_notification_lambda" {
  security_group_id            = aws_security_group.secrets_manager_endpoint.id
  referenced_security_group_id = aws_security_group.notification_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "notification_lambda_to_secrets_endpoint" {
  security_group_id            = aws_security_group.notification_lambda.id
  referenced_security_group_id = aws_security_group.secrets_manager_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "order_lambda_to_product_service" {
  count = var.product_adapter_mode == "HTTP" ? 1 : 0

  security_group_id = aws_security_group.order_lambda.id
  cidr_ipv4         = var.product_service_cidr
  ip_protocol       = "tcp"
  from_port         = var.product_service_port
  to_port           = var.product_service_port
}

resource "aws_vpc_security_group_ingress_rule" "sns_endpoint_from_order_lambda" {
  security_group_id            = aws_security_group.sns_endpoint.id
  referenced_security_group_id = aws_security_group.order_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "order_lambda_to_sns_endpoint" {
  security_group_id            = aws_security_group.order_lambda.id
  referenced_security_group_id = aws_security_group.sns_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "eventbridge_endpoint_from_payment_lambda" {
  security_group_id            = aws_security_group.eventbridge_endpoint.id
  referenced_security_group_id = aws_security_group.payment_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "payment_lambda_to_eventbridge_endpoint" {
  security_group_id            = aws_security_group.payment_lambda.id
  referenced_security_group_id = aws_security_group.eventbridge_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

data "aws_iam_policy_document" "secrets_manager_endpoint" {
  statement {
    sid       = "ReadOnlyPaymentDatabaseSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.payment.master_user_secret[0].secret_arn]

    principals {
      type = "AWS"
      identifiers = [
        aws_iam_role.payment_consumer.arn,
        aws_iam_role.payment_outbox.arn,
        aws_iam_role.order_command.arn,
        aws_iam_role.order_query.arn,
        aws_iam_role.order_outbox.arn,
        aws_iam_role.order_payment_result.arn,
        aws_iam_role.notification_demo.arn
      ]
    }
  }
}

resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = aws_vpc.payment.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.payment_private[*].id
  security_group_ids  = [aws_security_group.secrets_manager_endpoint.id]
  policy              = data.aws_iam_policy_document.secrets_manager_endpoint.json

  tags = {
    Name = "${local.name_prefix}-secrets-manager"
  }
}

data "aws_iam_policy_document" "eventbridge_endpoint" {
  statement {
    sid       = "PublishOnlyPaymentResults"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.payment_events.arn]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.payment_outbox.arn]
    }
  }
}

resource "aws_vpc_endpoint" "eventbridge" {
  vpc_id              = aws_vpc.payment.id
  service_name        = "com.amazonaws.${var.aws_region}.events"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.payment_private[*].id
  security_group_ids  = [aws_security_group.eventbridge_endpoint.id]
  policy              = data.aws_iam_policy_document.eventbridge_endpoint.json
  tags = {
    Name = "${local.name_prefix}-eventbridge"
  }
}

data "aws_iam_policy_document" "sns_endpoint" {
  statement {
    sid       = "PublishOnlyOrderEvents"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.order_events.arn]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.order_outbox.arn]
    }
  }
}

resource "aws_vpc_endpoint" "sns" {
  vpc_id              = aws_vpc.payment.id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.payment_private[*].id
  security_group_ids  = [aws_security_group.sns_endpoint.id]
  policy              = data.aws_iam_policy_document.sns_endpoint.json
  tags = {
    Name = "${local.name_prefix}-sns"
  }
}
