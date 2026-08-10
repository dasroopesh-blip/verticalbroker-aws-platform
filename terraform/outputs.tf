# Root Module Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exports key resource identifiers for cross-module references and external consumption.
# Outputs are organized by domain module.

# ---------------------------------------------------------
# PLATFORM METADATA
# ---------------------------------------------------------

output "platform_name" {
  description = "Platform identifier"
  value       = var.platform_name
}

output "environment" {
  description = "Current deployment environment"
  value       = var.environment
}

output "aws_region" {
  description = "Primary AWS region"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "Target AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "name_prefix" {
  description = "Resource naming prefix: {platform}-{environment}"
  value       = local.name_prefix
}

output "mandatory_tags" {
  description = "Mandatory tags applied to all resources"
  value       = local.default_tags
}

# ---------------------------------------------------------
# NETWORKING OUTPUTS (populated when networking module is enabled)
# ---------------------------------------------------------

# output "vpc_id" {
#   description = "VPC ID for the platform"
#   value       = module.networking.vpc_id
# }

# output "private_subnet_ids" {
#   description = "Private subnet IDs across availability zones"
#   value       = module.networking.private_subnet_ids
# }

# output "transit_gateway_id" {
#   description = "Transit Gateway ID for cross-account connectivity"
#   value       = module.networking.transit_gateway_id
# }

# ---------------------------------------------------------
# SECURITY OUTPUTS (populated when security module is enabled)
# ---------------------------------------------------------

# output "kms_key_arns" {
#   description = "KMS key ARNs by data classification"
#   value       = module.security.kms_key_arns
# }

# output "iam_role_arns" {
#   description = "IAM role ARNs for platform services"
#   value       = module.security.iam_role_arns
# }

# ---------------------------------------------------------
# DATA LAKE OUTPUTS (populated when data-lake module is enabled)
# ---------------------------------------------------------

# output "bronze_bucket_arn" {
#   description = "S3 Bronze layer bucket ARN"
#   value       = module.data_lake.bronze_bucket_arn
# }

# output "silver_bucket_arn" {
#   description = "S3 Silver layer bucket ARN"
#   value       = module.data_lake.silver_bucket_arn
# }

# output "gold_bucket_arn" {
#   description = "S3 Gold layer bucket ARN"
#   value       = module.data_lake.gold_bucket_arn
# }

# output "glue_database_names" {
#   description = "Glue Data Catalog database names"
#   value       = module.data_lake.glue_database_names
# }

# ---------------------------------------------------------
# STREAMING OUTPUTS (populated when streaming module is enabled)
# ---------------------------------------------------------

# output "kinesis_stream_arn" {
#   description = "Kinesis Data Stream ARN for market data ingestion"
#   value       = module.streaming.kinesis_stream_arn
# }

# output "eventbridge_bus_arn" {
#   description = "EventBridge event bus ARN"
#   value       = module.streaming.eventbridge_bus_arn
# }

# ---------------------------------------------------------
# COMPUTE OUTPUTS (populated when compute module is enabled)
# ---------------------------------------------------------

# output "api_gateway_endpoint" {
#   description = "API Gateway endpoint URL"
#   value       = module.compute.api_gateway_endpoint
# }

# output "lambda_function_arns" {
#   description = "Lambda function ARNs by service"
#   value       = module.compute.lambda_function_arns
# }

# ---------------------------------------------------------
# TERRAFORM STATE METADATA
# ---------------------------------------------------------

output "terraform_state_bucket" {
  description = "S3 bucket storing Terraform state for this environment"
  value       = "verticalbroker-terraform-state-${var.environment}"
}

output "terraform_lock_table" {
  description = "DynamoDB table for Terraform state locking"
  value       = "verticalbroker-terraform-locks-${var.environment}"
}
