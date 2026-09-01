mock_provider "aws" {}

run "creates_named_source_and_dlq" {
  command = plan

  variables {
    name                       = "example-dev-payment"
    visibility_timeout_seconds = 180
    max_receive_count          = 5
    sender_service             = "sns.amazonaws.com"
    sender_source_arns         = ["arn:aws:sns:sa-east-1:123456789012:orders"]
    source_account_id          = "123456789012"
  }

  assert {
    condition     = output.queue_name == "example-dev-payment-queue"
    error_message = "The source queue naming contract changed."
  }

  assert {
    condition     = output.dlq_name == "example-dev-payment-dlq"
    error_message = "The DLQ naming contract changed."
  }
}
