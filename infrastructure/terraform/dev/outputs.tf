output "order_events_topic_arn" {
  description = "Publish the Phase 1 OrderCreated test event to this SNS topic."
  value       = aws_sns_topic.order_events.arn
}

output "payment_order_created_queue_url" {
  description = "Payment consumer source queue URL."
  value       = module.payment_order_created_queue.queue_url
}

output "notification_order_created_queue_url" {
  description = "Notification consumer source queue URL."
  value       = module.notification_order_created_queue.queue_url
}

output "payment_order_created_dlq_url" {
  description = "Payment flow dead-letter queue URL."
  value       = module.payment_order_created_queue.dlq_url
}

output "notification_order_created_dlq_url" {
  description = "Notification flow dead-letter queue URL."
  value       = module.notification_order_created_queue.dlq_url
}

output "payment_lambda_log_group" {
  description = "CloudWatch log group for the Payment OrderCreated consumer."
  value       = aws_cloudwatch_log_group.payment_consumer.name
}

output "notification_demo_lambda_log_group" {
  description = "CloudWatch log group for the Notification Demo consumer."
  value       = aws_cloudwatch_log_group.notification_demo.name
}

output "payment_database_address" {
  description = "Private RDS hostname used by Payment Lambda."
  value       = aws_db_instance.payment.address
}

output "payment_database_name" {
  description = "Initial PostgreSQL database name."
  value       = aws_db_instance.payment.db_name
}

output "payment_database_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret; the secret value is never output."
  value       = aws_db_instance.payment.master_user_secret[0].secret_arn
}

output "payment_vpc_id" {
  description = "VPC containing Payment Lambda, RDS, and the Secrets Manager endpoint."
  value       = aws_vpc.payment.id
}

output "payment_event_bus_name" {
  description = "Custom EventBridge bus receiving PaymentProcessed and PaymentFailed."
  value       = aws_cloudwatch_event_bus.payment_events.name
}

output "order_payment_result_queue_url" {
  description = "Order payment-result consumer queue URL."
  value       = module.order_payment_result_queue.queue_url
}

output "order_payment_result_dlq_url" {
  description = "Order payment-result consumer DLQ URL."
  value       = module.order_payment_result_queue.dlq_url
}

output "notification_payment_result_queue_url" {
  description = "Notification payment-result queue URL."
  value       = module.notification_payment_result_queue.queue_url
}

output "notification_payment_result_dlq_url" {
  description = "Notification payment-result DLQ URL."
  value       = module.notification_payment_result_queue.dlq_url
}

output "order_payment_result_log_group" {
  description = "CloudWatch log group for the Order payment-result consumer."
  value       = aws_cloudwatch_log_group.order_payment_result.name
}

output "order_api_endpoint" {
  description = "HTTP API endpoint; create with POST /orders and inspect eventual status with GET /orders/{orderId}."
  value       = aws_apigatewayv2_api.orders.api_endpoint
}

output "order_api_authorization_type" {
  description = "Configured authorization mode for both Order API routes."
  value       = var.order_api_authorization_type
}

output "order_api_invoke_arns" {
  description = "Route-scoped execute-api ARNs to grant to an approved caller identity."
  value = {
    create_order = local.order_create_invoke_arn
    get_order    = local.order_query_invoke_arn
  }
}

output "order_query_log_group" {
  description = "CloudWatch log group for the read-only Order query Lambda."
  value       = aws_cloudwatch_log_group.order_query.name
}

output "order_api_access_log_group" {
  description = "Structured API Gateway access-log group for the Order HTTP API."
  value       = aws_cloudwatch_log_group.order_api_access.name
}

output "payment_outbox_log_group" {
  value = aws_cloudwatch_log_group.payment_outbox.name
}

output "order_outbox_log_group" {
  value = aws_cloudwatch_log_group.order_outbox.name
}

output "observability_dashboard_name" {
  description = "CloudWatch dashboard for queues, Lambdas, EventBridge, Outboxes, and PostgreSQL."
  value       = module.observability.dashboard_name
}

output "operational_alarm_topic_arn" {
  description = "SNS topic used by CloudWatch alarms; subscribe an operator endpoint after deployment."
  value       = module.observability.alarm_topic_arn
}

output "observability_metric_namespace" {
  description = "CloudWatch namespace populated from Outbox EMF log events."
  value       = local.observability_metric_namespace
}
