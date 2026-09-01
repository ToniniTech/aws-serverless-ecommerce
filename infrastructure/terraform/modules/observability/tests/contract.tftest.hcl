mock_provider "aws" {}

run "creates_environment_dashboard" {
  command = plan

  variables {
    name_prefix              = "example-dev"
    aws_region               = "sa-east-1"
    metric_namespace         = "example/dev"
    source_account_id        = "123456789012"
    source_queues            = { payment = "payment-queue" }
    dlqs                     = { payment = "payment-dlq" }
    lambdas                  = { payment = "payment-function" }
    application_log_groups   = { payment = "/aws/lambda/payment-function" }
    eventbridge_rules        = { payment = { rule_name = "payment-rule", event_bus_name = "payment-bus" } }
    outbox_publishers        = ["payment-outbox"]
    api_id                   = "api-id"
    api_stage                = "$default"
    db_instance_identifier   = "payment-db"
    queue_age_alarm_seconds  = 300
    outbox_age_alarm_seconds = 300
    alarm_evaluation_periods = 2
  }

  assert {
    condition     = output.dashboard_name == "example-dev-workflow"
    error_message = "The dashboard naming contract changed."
  }
}
