# Backend Configuration - Disaster Recovery Environment
# S3 backend with DynamoDB state locking for VerticalBroker platform
# Requirements: 13.3 (S3 state with DynamoDB locking, encryption, cross-account access)
# Requirements: 16.2, 16.4 (RTO 4h, RPO 1h, secondary region infrastructure)

terraform {
  backend "s3" {
    bucket         = "verticalbroker-terraform-state-dr"
    key            = "dr/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-dr"

    # Cross-account access for CI/CD pipeline service role
    role_arn = "arn:aws:iam::SHARED_SERVICES_ACCOUNT_ID:role/TerraformStateCrossAccountRole"
  }
}
