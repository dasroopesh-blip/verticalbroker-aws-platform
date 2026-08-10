# Backend Configuration - Global Resources
# S3 backend for Organization-level resources (deployed once, not per-environment)
# Requirements: 13.3

terraform {
  backend "s3" {
    bucket         = "verticalbroker-terraform-state-global"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-global"

    # Management account access
    role_arn = "arn:aws:iam::MANAGEMENT_ACCOUNT_ID:role/TerraformStateCrossAccountRole"
  }
}
