output "dashboard_name" {
  value = aws_cloudwatch_dashboard.workflow.dashboard_name
}

output "alarm_topic_arn" {
  value = aws_sns_topic.operational_alerts.arn
}
