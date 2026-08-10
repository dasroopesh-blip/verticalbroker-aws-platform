# Backend Configuration - Staging Environment
# S3 backend with DynamoDB state locking for VerticalBroker platform
# Requirements: 13.3 (S3 state with DynamoDB locking, encryption, cross-account access)

terraform {
  backend "s3" {
    bucket         = "verticalbroker-terraform-state-staging"
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-staging"

    # Cross-account access for CI/CD pipeline service role
    role_arn = "arn:aws:iam::SHARED_SERVICES_ACCOUNT_ID:role/TerraformStateCrossAccountRole"
  }
}
