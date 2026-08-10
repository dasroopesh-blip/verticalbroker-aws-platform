# Staging Environment Variables
# Requirements: 13.2, 13.5

environment          = "staging"
aws_region           = "us-east-1"
aws_account_id       = "STAGING_ACCOUNT_ID"
organizational_unit  = "DataLake"

# Mandatory tags (Requirement 13.5)
default_tags = {
  Environment        = "staging"
  Service            = "verticalbroker-platform"
  Owner              = "data-engineering"
  CostCenter         = "DE-001"
  DataClassification = "Internal"
  Compliance         = "FINRA-4511"
}

# Networking
vpc_cidr             = "10.2.0.0/16"
enable_transit_gateway = true

# Compute scaling (moderate for staging)
lambda_reserved_concurrency_trade    = 100
lambda_reserved_concurrency_advisory = 50
lambda_reserved_concurrency_ingestion = 200
glue_max_dpus        = 50

# Data retention (moderate for staging)
bronze_glacier_transition_days = 60
log_retention_days             = 60
