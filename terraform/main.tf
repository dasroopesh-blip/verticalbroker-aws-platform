# Root Module Configuration
# VerticalBroker AWS Data Engineering Platform
#
# This root module composes all domain-specific modules into a complete platform deployment.
# Modules are organized by domain: networking, security, data-lake, streaming, compute,
# analytics, ml, and monitoring.
#
# Requirements: 13.1 (Composable modules by domain)
# Requirements: 13.2 (Multi-account deployment support)
# Requirements: 13.5 (Mandatory tags on all resources)

# ---------------------------------------------------------
# LOCAL VALUES
# Computed values used across the root module
# ---------------------------------------------------------

locals {
  # Resolve mandatory tags from individual variables or the map variable
  default_tags = length(var.mandatory_tags) > 0 ? var.mandatory_tags : {
    Environment        = var.tag_environment
    Service            = var.tag_service
    Owner              = var.tag_owner
    CostCenter         = var.tag_cost_center
    DataClassification = var.tag_data_classification
    Compliance         = var.tag_compliance
    ManagedBy          = "terraform"
  }

  # Resource naming convention: {platform}-{service}-{environment}
  name_prefix = "${var.platform_name}-${var.environment}"

  # Account and region metadata
  account_metadata = {
    account_id          = var.aws_account_id
    region              = var.aws_region
    dr_region           = var.dr_region
    organizational_unit = var.organizational_unit
    environment         = var.environment
  }

  # Common module input block for consistent parameterization
  common_module_inputs = {
    environment         = var.environment
    platform_name       = var.platform_name
    name_prefix         = local.name_prefix
    aws_region          = var.aws_region
    aws_account_id      = var.aws_account_id
    mandatory_tags      = local.default_tags
  }
}

# ---------------------------------------------------------
# DATA SOURCES
# ---------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ---------------------------------------------------------
# MODULE COMPOSITION
# Domain modules are composed here. Each module is enabled/disabled
# based on environment requirements.
# ---------------------------------------------------------

# Module: Networking
# Provides VPC, subnets, Transit Gateway, VPC Endpoints, Security Groups
# Requirement 20: Multi-Account and Network Architecture
# module "networking" {
#   source = "./modules/networking"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   vpc_cidr             = var.vpc_cidr
#   min_availability_zones = var.min_availability_zones
#   enable_transit_gateway = var.enable_transit_gateway
#   mandatory_tags       = local.default_tags
# }

# Module: Security
# Provides KMS keys, IAM roles/policies, GuardDuty, Security Hub
# Requirement 14: Security and Compliance
# module "security" {
#   source = "./modules/security"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   aws_account_id       = var.aws_account_id
#   data_classification  = var.tag_data_classification
#   mandatory_tags       = local.default_tags
# }

# Module: Data Lake
# Provides S3 buckets (Bronze/Silver/Gold), Glue Data Catalog, lifecycle policies
# Requirement 2, 3, 4: Data Lake layers
# module "data_lake" {
#   source = "./modules/data-lake"
#
#   environment                    = var.environment
#   platform_name                  = var.platform_name
#   name_prefix                    = local.name_prefix
#   bronze_glacier_transition_days = var.bronze_glacier_transition_days
#   enable_cross_region_replication = var.enable_cross_region_replication
#   dr_region                      = var.dr_region
#   kms_key_arn                    = module.security.kms_key_arns["Confidential"]
#   mandatory_tags                 = local.default_tags
# }

# Module: Streaming
# Provides Kinesis Data Streams, EventBridge, SQS queues
# Requirements 1, 6: Market Data Ingestion and Event-Driven Architecture
# module "streaming" {
#   source = "./modules/streaming"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   mandatory_tags       = local.default_tags
# }

# Module: Compute
# Provides Lambda functions, Step Functions, API Gateway
# Requirements 7, 8: Serverless Compute and API Gateway
# module "compute" {
#   source = "./modules/compute"
#
#   environment                           = var.environment
#   platform_name                         = var.platform_name
#   name_prefix                           = local.name_prefix
#   lambda_reserved_concurrency_trade     = var.lambda_reserved_concurrency_trade
#   lambda_reserved_concurrency_advisory  = var.lambda_reserved_concurrency_advisory
#   lambda_reserved_concurrency_ingestion = var.lambda_reserved_concurrency_ingestion
#   mandatory_tags                        = local.default_tags
# }

# Module: Analytics
# Provides OpenSearch, Neptune, Athena
# Requirements 9, 10, 11: Search, Graph, SQL
# module "analytics" {
#   source = "./modules/analytics"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   mandatory_tags       = local.default_tags
# }

# Module: ML
# Provides SageMaker training, endpoints, model registry
# Requirement 12: RL Advisory Agent
# module "ml" {
#   source = "./modules/ml"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   mandatory_tags       = local.default_tags
# }

# Module: Monitoring
# Provides CloudWatch dashboards, alarms, X-Ray, log groups
# Requirement 15: Monitoring and Observability
# module "monitoring" {
#   source = "./modules/monitoring"
#
#   environment          = var.environment
#   platform_name        = var.platform_name
#   name_prefix          = local.name_prefix
#   log_retention_days   = var.log_retention_days
#   mandatory_tags       = local.default_tags
# }
