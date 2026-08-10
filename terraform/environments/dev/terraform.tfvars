# Development Environment Variables
# Requirements: 13.2, 13.5

environment          = "dev"
aws_region           = "us-east-1"
aws_account_id       = "DEV_ACCOUNT_ID"
organizational_unit  = "DataLake"

# Mandatory tags (Requirement 13.5)
default_tags = {
  Environment        = "dev"
  Service            = "verticalbroker-platform"
  Owner              = "data-engineering"
  CostCenter         = "DE-001"
  DataClassification = "Internal"
  Compliance         = "FINRA-4511"
}

# Networking
vpc_cidr             = "10.1.0.0/16"
enable_transit_gateway = false

# Compute scaling (reduced for dev)
lambda_reserved_concurrency_trade    = 10
lambda_reserved_concurrency_advisory = 5
lambda_reserved_concurrency_ingestion = 20
glue_max_dpus        = 10

# Data retention (reduced for dev)
bronze_glacier_transition_days = 30
log_retention_days             = 30
