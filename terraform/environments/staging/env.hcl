# Staging Environment Configuration
# Used by Terragrunt to resolve environment-specific locals

locals {
  environment          = "staging"
  aws_region           = "us-east-1"
  aws_account_id       = "STAGING_ACCOUNT_ID"
  dr_region            = "us-west-2"
  data_classification  = "Internal"
  organizational_unit  = "DataLake"
}
