variable "name" {
  description = "Base flow name; the module appends -queue and -dlq."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Source queue visibility timeout."
  type        = number
}

variable "max_receive_count" {
  description = "Receives allowed before redrive to the dedicated DLQ."
  type        = number
}

variable "sender_service" {
  description = "AWS service principal allowed to send to the source queue."
  type        = string
  validation {
    condition     = contains(["sns.amazonaws.com", "events.amazonaws.com"], var.sender_service)
    error_message = "sender_service must be SNS or EventBridge."
  }
}

variable "sender_source_arns" {
  description = "Exact SNS topic or EventBridge rule ARNs allowed to send."
  type        = list(string)
  validation {
    condition     = length(var.sender_source_arns) > 0
    error_message = "At least one sender source ARN is required."
  }
}

variable "source_account_id" {
  description = "AWS account that owns the permitted sender resources."
  type        = string
}

variable "message_retention_seconds" {
  type    = number
  default = 345600
}

variable "dlq_retention_seconds" {
  type    = number
  default = 1209600
}

variable "receive_wait_time_seconds" {
  type    = number
  default = 20
}
