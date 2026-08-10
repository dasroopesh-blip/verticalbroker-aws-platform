# Disaster Recovery Environment Configuration
# Used by Terragrunt to resolve environment-specific locals

locals {
  environment          = "dr"
  aws_region           = "us-west-2"
  aws_account_id       = "DR_ACCOUNT_ID"
  dr_region            = "us-east-1"  # DR region points back to primary
  data_classification  = "Confidential"
  organizational_unit  = "DR"
}
