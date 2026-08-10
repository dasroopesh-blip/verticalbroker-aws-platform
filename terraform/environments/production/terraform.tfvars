# Production Environment Variables
# Requirements: 13.2, 13.5, 16.1, 16.6

environment          = "production"
aws_region           = "us-east-1"
aws_account_id       = "PRODUCTION_ACCOUNT_ID"
organizational_unit  = "DataLake"

# Mandatory tags (Requirement 13.5)
default_tags = {
  Environment        = "production"
  Service            = "verticalbroker-platform"
  Owner              = "data-engineering"
  CostCenter         = "DE-001"
  DataClassification = "Confidential"
  Compliance         = "FINRA-4511"
}

# Networking
vpc_cidr             = "10.0.0.0/16"
enable_transit_gateway = true

# Compute scaling (full production capacity)
# Requirement 7.4: Reserved concurrency for critical functions
lambda_reserved_concurrency_trade    = 1000
lambda_reserved_concurrency_advisory = 500
lambda_reserved_concurrency_ingestion = 2000
glue_max_dpus        = 100

# Data retention (full FINRA compliance)
# Requirement 14.4: 7-year retention for FINRA 4511
bronze_glacier_transition_days = 90
log_retention_days             = 90

# High availability (Requirement 16.6)
enable_multi_az          = true
min_availability_zones   = 3
enable_cross_region_replication = true
dr_region                = "us-west-2"
