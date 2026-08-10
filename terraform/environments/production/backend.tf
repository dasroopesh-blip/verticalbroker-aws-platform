# Backend Configuration - Production Environment
# S3 backend with DynamoDB state locking for VerticalBroker platform
# Requirements: 13.3 (S3 state with DynamoDB locking, encryption, cross-account access)
# Requirements: 16.3 (Cross-region replication for Terraform state)

terraform {
  backend "s3" {
    bucket         = "verticalbroker-terraform-state-production"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-production"

    # Cross-account access for CI/CD pipeline service role
    role_arn = "arn:aws:iam::SHARED_SERVICES_ACCOUNT_ID:role/TerraformStateCrossAccountRole"
  }
}
