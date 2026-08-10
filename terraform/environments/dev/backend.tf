# Backend Configuration - Development Environment
# S3 backend with DynamoDB state locking for VerticalBroker platform
# Requirements: 13.3 (S3 state with DynamoDB locking, encryption, cross-account access)

terraform {
  backend "s3" {
    bucket         = "verticalbroker-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-dev"

    # Cross-account access for CI/CD pipeline service role
    role_arn = "arn:aws:iam::SHARED_SERVICES_ACCOUNT_ID:role/TerraformStateCrossAccountRole"

    # State file versioning for rollback capability
    # S3 bucket versioning is enabled at the bucket level
  }
}
