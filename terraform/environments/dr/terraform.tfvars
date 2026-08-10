# Disaster Recovery Environment Variables
# Requirements: 13.2, 13.5, 16.2, 16.3, 16.4

environment          = "dr"
aws_region           = "us-west-2"
aws_account_id       = "DR_ACCOUNT_ID"
organizational_unit  = "DR"

# Mandatory tags (Requirement 13.5)
default_tags = {
  Environment        = "dr"
  Service            = "verticalbroker-platform"
  Owner              = "data-engineering"
  CostCenter         = "DE-001"
  DataClassification = "Confidential"
  Compliance         = "FINRA-4511"
}

# Networking
vpc_cidr             = "10.3.0.0/16"
enable_transit_gateway = true

# Compute scaling (matches production for RTO compliance)
# Requirement 16.2: RTO 4 hours requires pre-provisioned infrastructure
lambda_reserved_concurrency_trade    = 1000
lambda_reserved_concurrency_advisory = 500
lambda_reserved_concurrency_ingestion = 2000
glue_max_dpus        = 100

# Data retention (matches production)
bronze_glacier_transition_days = 90
log_retention_days             = 90

# DR-specific settings
enable_multi_az          = true
min_availability_zones   = 3
is_dr_environment        = true
primary_region           = "us-east-1"
