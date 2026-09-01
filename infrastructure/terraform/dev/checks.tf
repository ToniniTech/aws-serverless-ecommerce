check "production_database_safety" {
  assert {
    condition = var.environment != "prod" || (
      var.payment_database_deletion_protection &&
      !var.payment_database_skip_final_snapshot &&
      var.payment_database_multi_az &&
      var.payment_database_backup_retention_days >= 7
    )
    error_message = "prod requires deletion protection, a final snapshot, Multi-AZ, and at least seven backup days."
  }
}

check "expected_aws_account" {
  assert {
    condition     = var.expected_aws_account_id == null || var.expected_aws_account_id == data.aws_caller_identity.current.account_id
    error_message = "The authenticated AWS account does not match expected_aws_account_id."
  }
}

check "lambda_database_connection_budget" {
  assert {
    condition     = var.payment_db_max_pool_size * 2 * 5 <= 40
    error_message = "Configured pools and concurrency exceed the educational RDS connection budget."
  }
}

check "http_product_adapter_configuration" {
  assert {
    condition = var.product_adapter_mode != "HTTP" || (
      try(trimspace(var.product_service_base_url), "") != ""
    )
    error_message = "product_service_base_url is required when product_adapter_mode is HTTP."
  }
}

check "production_api_authorization" {
  assert {
    condition     = var.environment != "prod" || var.order_api_authorization_type == "AWS_IAM"
    error_message = "prod requires AWS_IAM authorization for every Order API route."
  }
}
