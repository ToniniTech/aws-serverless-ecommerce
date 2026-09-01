provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    events = var.localstack_endpoint
    iam    = var.localstack_endpoint
    lambda = var.localstack_endpoint
    sns    = var.localstack_endpoint
    sqs    = var.localstack_endpoint
    sfn    = var.localstack_endpoint
  }

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "local"
      ManagedBy   = "Terraform"
      Phase       = "Z1"
    }
  }
}
