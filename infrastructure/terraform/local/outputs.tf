output "order_events_topic_arn" {
  value = aws_sns_topic.order_events.arn
}

output "payment_events_bus_name" {
  value = aws_cloudwatch_event_bus.payment_events.name
}

output "payment_order_created_queue_url" {
  value = module.payment_order_created_queue.queue_url
}

output "payment_order_created_dlq_url" {
  value = module.payment_order_created_queue.dlq_url
}

output "notification_order_created_queue_url" {
  value = module.notification_order_created_queue.queue_url
}

output "notification_order_created_dlq_url" {
  value = module.notification_order_created_queue.dlq_url
}

output "order_payment_result_queue_url" {
  value = module.order_payment_result_queue.queue_url
}

output "order_payment_result_dlq_url" {
  value = module.order_payment_result_queue.dlq_url
}

output "notification_payment_result_queue_url" {
  value = module.notification_payment_result_queue.queue_url
}

output "notification_payment_result_dlq_url" {
  value = module.notification_payment_result_queue.dlq_url
}

output "max_receive_count" {
  value = var.max_receive_count
}

output "order_command_function_name" {
  value = aws_lambda_function.order_command.function_name
}

output "order_query_function_name" {
  value = aws_lambda_function.order_query.function_name
}

output "order_outbox_function_name" {
  value = aws_lambda_function.order_outbox.function_name
}

output "payment_outbox_function_name" {
  value = aws_lambda_function.payment_outbox.function_name
}

output "notification_function_name" {
  description = "Name of the durable local Notification consumer Lambda."
  value       = aws_lambda_function.notification_demo.function_name
}

output "order_saga_state_machine_arn" {
  description = "ARN of the isolated local Step Functions Order Saga."
  value       = aws_sfn_state_machine.order_saga.arn
}
