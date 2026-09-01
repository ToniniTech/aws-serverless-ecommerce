variable "aws_region" {
  description = "AWS region for the development environment."
  type        = string
  default     = "sa-east-1"
}

variable "expected_aws_account_id" {
  description = "Optional guardrail that makes planning fail in the wrong AWS account."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.expected_aws_account_id == null || can(regex("^[0-9]{12}$", var.expected_aws_account_id))
    error_message = "expected_aws_account_id must be null or a 12-digit AWS account ID."
  }
}

variable "project_name" {
  description = "Prefix used for development resource names."
  type        = string
  default     = "serverless-ecommerce"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "project_name must be 3-31 lowercase letters, digits, or hyphens and start with a letter."
  }
}

variable "environment" {
  description = "Environment name included in resource names and tags."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention for application and API access logs."
  type        = number
  default     = 14
  validation {
    condition     = contains([7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a supported CloudWatch retention value."
  }
}

variable "payment_lambda_timeout_seconds" {
  description = "Timeout for the PostgreSQL-backed Payment Lambda."
  type        = number
  default     = 30

  validation {
    condition     = var.payment_lambda_timeout_seconds >= 10 && var.payment_lambda_timeout_seconds <= 60
    error_message = "Payment Lambda timeout must be between 10 and 60 seconds."
  }
}

variable "notification_lambda_timeout_seconds" {
  description = "Timeout for the logging-only Notification Demo Lambda."
  type        = number
  default     = 15

  validation {
    condition     = var.notification_lambda_timeout_seconds >= 1 && var.notification_lambda_timeout_seconds <= 30
    error_message = "Notification Demo Lambda timeout must be between 1 and 30 seconds."
  }
}

variable "order_payment_result_lambda_timeout_seconds" {
  description = "Timeout for the PostgreSQL-backed Order payment-result Lambda."
  type        = number
  default     = 30
  validation {
    condition     = var.order_payment_result_lambda_timeout_seconds >= 10 && var.order_payment_result_lambda_timeout_seconds <= 60
    error_message = "Order payment-result Lambda timeout must be between 10 and 60 seconds."
  }
}

variable "order_payment_result_queue_visibility_timeout_seconds" {
  description = "Order payment-result SQS visibility timeout; at least six times its Lambda timeout."
  type        = number
  default     = 180
  validation {
    condition     = var.order_payment_result_queue_visibility_timeout_seconds >= var.order_payment_result_lambda_timeout_seconds * 6
    error_message = "Order payment-result queue visibility timeout must be at least six times its Lambda timeout."
  }
}

variable "payment_queue_visibility_timeout_seconds" {
  description = "Payment SQS visibility timeout; at least six times its Lambda timeout."
  type        = number
  default     = 180

  validation {
    condition     = var.payment_queue_visibility_timeout_seconds >= var.payment_lambda_timeout_seconds * 6
    error_message = "Payment queue visibility timeout must be at least six times the Payment Lambda timeout."
  }
}

variable "notification_queue_visibility_timeout_seconds" {
  description = "Notification Demo SQS visibility timeout; at least six times its Lambda timeout."
  type        = number
  default     = 90

  validation {
    condition     = var.notification_queue_visibility_timeout_seconds >= var.notification_lambda_timeout_seconds * 6
    error_message = "Notification queue visibility timeout must be at least six times its Lambda timeout."
  }
}

variable "max_receive_count" {
  description = "Number of receives before SQS moves a message to its flow-specific DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 2
    error_message = "max_receive_count must be at least 2."
  }
}

variable "payment_lambda_artifact" {
  description = "Path relative to this Terraform root for the shaded Payment Lambda JAR."
  type        = string
  default     = "../../../payment-order-created-lambda/target/payment-order-created-lambda.jar"
}

variable "notification_demo_lambda_artifact" {
  description = "Path relative to this Terraform root for the shaded Notification Demo Lambda JAR."
  type        = string
  default     = "../../../notification-demo-lambda/target/notification-demo-lambda.jar"
}

variable "order_payment_result_lambda_artifact" {
  description = "Path relative to this Terraform root for the shaded Order payment-result Lambda JAR."
  type        = string
  default     = "../../../order-payment-result-lambda/target/order-payment-result-lambda.jar"
}

variable "vpc_cidr" {
  description = "CIDR for the isolated educational Payment VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "payment_database_name" {
  description = "Initial PostgreSQL database used by Payment."
  type        = string
  default     = "payments"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.payment_database_name))
    error_message = "payment_database_name must be a lowercase PostgreSQL identifier."
  }
}

variable "payment_database_username" {
  description = "RDS-managed master username; its generated password is stored by RDS in Secrets Manager."
  type        = string
  default     = "payment_admin"
}

variable "payment_database_instance_class" {
  description = "Small single-AZ RDS instance class for the AWS development environment."
  type        = string
  default     = "db.t4g.micro"
}

variable "payment_database_allocated_storage_gb" {
  description = "Allocated gp3 storage for the Payment development database."
  type        = number
  default     = 20
}

variable "payment_database_multi_az" {
  description = "Whether RDS uses a standby in another Availability Zone."
  type        = bool
  default     = false
}

variable "payment_database_backup_retention_days" {
  description = "Automated RDS backup retention."
  type        = number
  default     = 1
  validation {
    condition     = var.payment_database_backup_retention_days >= 1 && var.payment_database_backup_retention_days <= 35
    error_message = "RDS backup retention must be between 1 and 35 days."
  }
}

variable "payment_database_deletion_protection" {
  description = "Protect the database from Terraform deletion. Required for prod by a root check."
  type        = bool
  default     = false
}

variable "payment_database_skip_final_snapshot" {
  description = "Skip the final RDS snapshot on destroy. Must be false for prod."
  type        = bool
  default     = true
}

variable "payment_database_performance_insights" {
  description = "Enable RDS Performance Insights."
  type        = bool
  default     = false
}

variable "order_api_throttling_burst_limit" {
  description = "HTTP API default-stage burst limit."
  type        = number
  default     = 20
}

variable "order_api_throttling_rate_limit" {
  description = "HTTP API steady-state requests per second."
  type        = number
  default     = 10
}

variable "order_api_authorization_type" {
  description = "Authorization for Order HTTP API routes. AWS_IAM requires SigV4; NONE is restricted to isolated demonstrations."
  type        = string
  default     = "AWS_IAM"

  validation {
    condition     = contains(["AWS_IAM", "NONE"], var.order_api_authorization_type)
    error_message = "order_api_authorization_type must be AWS_IAM or NONE."
  }
}

variable "payment_db_max_pool_size" {
  description = "Maximum JDBC connections held by each warm Payment Lambda environment."
  type        = number
  default     = 2

  validation {
    condition     = var.payment_db_max_pool_size >= 1 && var.payment_db_max_pool_size <= 4
    error_message = "payment_db_max_pool_size must be between 1 and 4."
  }
}

variable "outbox_batch_size" {
  description = "Maximum Outbox rows claimed by one scheduled publisher invocation."
  type        = number
  default     = 10
  validation {
    condition     = var.outbox_batch_size >= 1 && var.outbox_batch_size <= 100
    error_message = "outbox_batch_size must be between 1 and 100."
  }
}

variable "outbox_claim_lease_seconds" {
  description = "Time after which an abandoned PROCESSING Outbox row can be reclaimed."
  type        = number
  default     = 120
}

variable "product_service_base_url" {
  description = "Private Product Service base URL reachable from the Order command Lambda VPC; required only in HTTP mode."
  type        = string
  default     = null
  nullable    = true
}

variable "product_adapter_mode" {
  description = "Product boundary used by Order creation: SIMULATED for the deployment demo or HTTP for the real synchronous comparison."
  type        = string
  default     = "SIMULATED"
  validation {
    condition     = contains(["SIMULATED", "HTTP"], var.product_adapter_mode)
    error_message = "product_adapter_mode must be SIMULATED or HTTP."
  }
}

variable "product_service_port" {
  description = "TCP port used by the private Product Service."
  type        = number
  default     = 8082
}

variable "product_service_cidr" {
  description = "Narrow CIDR containing the Product Service endpoint."
  type        = string
  default     = "10.42.0.0/16"
}

variable "queue_age_alarm_seconds" {
  description = "Age of the oldest source-queue message that indicates sustained processing delay."
  type        = number
  default     = 300
  validation {
    condition     = var.queue_age_alarm_seconds >= 60
    error_message = "queue_age_alarm_seconds must be at least 60 seconds."
  }
}

variable "outbox_age_alarm_seconds" {
  description = "Age of the oldest unpublished Outbox row that indicates a stale publisher flow."
  type        = number
  default     = 300
  validation {
    condition     = var.outbox_age_alarm_seconds >= 120
    error_message = "outbox_age_alarm_seconds must be at least 120 seconds."
  }
}

variable "alarm_evaluation_periods" {
  description = "Consecutive one-minute periods required by latency and stale-Outbox alarms."
  type        = number
  default     = 2
  validation {
    condition     = var.alarm_evaluation_periods >= 1 && var.alarm_evaluation_periods <= 10
    error_message = "alarm_evaluation_periods must be between 1 and 10."
  }
}
