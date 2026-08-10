# Production Environment Configuration
# Used by Terragrunt to resolve environment-specific locals

locals {
  environment          = "production"
  aws_region           = "us-east-1"
  aws_account_id       = "PRODUCTION_ACCOUNT_ID"
  dr_region            = "us-west-2"
  data_classification  = "Confidential"
  organizational_unit  = "DataLake"
}
