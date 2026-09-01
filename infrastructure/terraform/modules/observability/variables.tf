variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "metric_namespace" { type = string }
variable "source_account_id" { type = string }
variable "source_queues" { type = map(string) }
variable "dlqs" { type = map(string) }
variable "lambdas" { type = map(string) }
variable "application_log_groups" { type = map(string) }
variable "eventbridge_rules" {
  type = map(object({
    rule_name      = string
    event_bus_name = optional(string)
  }))
}
variable "outbox_publishers" { type = set(string) }
variable "api_id" { type = string }
variable "api_stage" { type = string }
variable "db_instance_identifier" { type = string }
variable "queue_age_alarm_seconds" { type = number }
variable "outbox_age_alarm_seconds" { type = number }
variable "alarm_evaluation_periods" { type = number }
