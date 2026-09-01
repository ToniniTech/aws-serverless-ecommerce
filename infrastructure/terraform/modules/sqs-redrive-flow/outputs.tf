output "queue_arn" {
  value = aws_sqs_queue.source.arn
}

output "queue_url" {
  value = aws_sqs_queue.source.url
}

output "queue_name" {
  value = aws_sqs_queue.source.name
}

output "queue_policy_id" {
  value = aws_sqs_queue_policy.source.id
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}
