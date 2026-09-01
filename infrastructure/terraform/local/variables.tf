variable "aws_region" {
  description = "Logical AWS region used by the local emulator."
  type        = string
  default     = "us-east-1"
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint reached by Terraform on the host."
  type        = string
  default     = "http://localhost:4566"
}

variable "local_account_id" {
  description = "Deterministic account ID used by LocalStack with the test access key."
  type        = string
  default     = "000000000000"
}

variable "project_name" {
  description = "Prefix for local resources."
  type        = string
  default     = "aws-serverless-ecommerce"
}

variable "visibility_timeout_seconds" {
  description = "Local visibility timeout compatible with the Java Lambda timeout."
  type        = number
  default     = 30

  validation {
    condition     = var.visibility_timeout_seconds >= 30
    error_message = "visibility_timeout_seconds must be at least the 30-second Lambda timeout."
  }
}

variable "payment_lambda_artifact" {
  description = "Payment shaded JAR relative to the local Terraform root."
  type        = string
  default     = "../../../payment-order-created-lambda/target/payment-order-created-lambda.jar"
}

variable "order_lambda_artifact" {
  description = "Order shaded JAR relative to the local Terraform root."
  type        = string
  default     = "../../../order-payment-result-lambda/target/order-payment-result-lambda.jar"
}

variable "notification_lambda_artifact" {
  description = "Notification shaded JAR relative to the local Terraform root."
  type        = string
  default     = "../../../notification-demo-lambda/target/notification-demo-lambda.jar"
}

variable "saga_lambda_artifact" {
  description = "Saga task shaded JAR relative to the local Terraform root."
  type        = string
  default     = "../../../saga-orchestration-lambda/target/saga-orchestration-lambda.jar"
}

variable "max_receive_count" {
  description = "Local receive limit before SQS moves a message to its DLQ."
  type        = number
  default     = 3

  validation {
    condition     = var.max_receive_count >= 2
    error_message = "max_receive_count must be at least 2."
  }
}
