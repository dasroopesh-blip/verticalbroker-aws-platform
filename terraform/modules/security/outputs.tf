# Security Module Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exports KMS key ARNs, IDs, aliases, and IAM role ARNs for consumption by other modules
# (data-lake, streaming, compute, analytics, monitoring)
#
# Requirements: 14.1 (Cross-module encryption key references)
# Requirements: 14.3 (Service role references for policy attachment)

# ---------------------------------------------------------
# KMS KEY ARNS - Primary Region
# ---------------------------------------------------------

output "kms_key_arns" {
  description = "Map of data classification level to KMS key ARN in the primary region"
  value = {
    for classification, key in aws_kms_key.classification :
    classification => key.arn
  }
}

output "kms_key_ids" {
  description = "Map of data classification level to KMS key ID in the primary region"
  value = {
    for classification, key in aws_kms_key.classification :
    classification => key.key_id
  }
}

# ---------------------------------------------------------
# KMS KEY ALIASES - Primary Region
# ---------------------------------------------------------

output "kms_key_aliases" {
  description = "Map of data classification level to KMS key alias name"
  value = {
    for classification, alias in aws_kms_alias.classification :
    classification => alias.name
  }
}

# ---------------------------------------------------------
# KMS KEY ARNS - DR Region (Replicas)
# ---------------------------------------------------------

output "kms_replica_key_arns" {
  description = "Map of data classification level to KMS replica key ARN in the DR region (empty if replication disabled)"
  value = {
    for classification, key in aws_kms_replica_key.dr :
    classification => key.arn
  }
}

output "kms_replica_key_ids" {
  description = "Map of data classification level to KMS replica key ID in the DR region (empty if replication disabled)"
  value = {
    for classification, key in aws_kms_replica_key.dr :
    classification => key.key_id
  }
}

# ---------------------------------------------------------
# CONVENIENCE KMS OUTPUTS - Specific Key References
# These simplify references from consuming modules
# ---------------------------------------------------------

output "confidential_key_arn" {
  description = "KMS key ARN for Confidential data classification (Bronze/Silver/Gold layers)"
  value       = aws_kms_key.classification["Confidential"].arn
}

output "restricted_key_arn" {
  description = "KMS key ARN for Restricted data classification (PII, regulatory data)"
  value       = aws_kms_key.classification["Restricted"].arn
}

output "internal_key_arn" {
  description = "KMS key ARN for Internal data classification (logs, metrics)"
  value       = aws_kms_key.classification["Internal"].arn
}

output "public_key_arn" {
  description = "KMS key ARN for Public data classification (reference data)"
  value       = aws_kms_key.classification["Public"].arn
}

# ---------------------------------------------------------
# KMS METADATA OUTPUTS
# ---------------------------------------------------------

output "key_rotation_enabled" {
  description = "Whether automatic annual key rotation is enabled on all CMKs"
  value       = var.enable_key_rotation
}

output "cross_region_replication_enabled" {
  description = "Whether cross-region key replication to DR region is active"
  value       = var.enable_cross_region_replication
}

output "data_classifications" {
  description = "List of data classification levels with CMKs provisioned"
  value       = var.data_classifications
}

# ---------------------------------------------------------
# IAM ROLE OUTPUTS
# ---------------------------------------------------------

output "permission_boundary_arn" {
  description = "ARN of the permission boundary policy applied to all platform roles"
  value       = aws_iam_policy.permission_boundary.arn
}

output "market_data_lambda_role_arn" {
  description = "ARN of the Market Data Lambda execution role"
  value       = aws_iam_role.market_data_lambda.arn
}

output "market_data_lambda_role_name" {
  description = "Name of the Market Data Lambda execution role"
  value       = aws_iam_role.market_data_lambda.name
}

output "etl_glue_role_arn" {
  description = "ARN of the ETL Glue job execution role"
  value       = aws_iam_role.etl_glue.arn
}

output "etl_glue_role_name" {
  description = "Name of the ETL Glue job execution role"
  value       = aws_iam_role.etl_glue.name
}

output "advisory_agent_role_arn" {
  description = "ARN of the Advisory Agent Lambda execution role"
  value       = aws_iam_role.advisory_agent.arn
}

output "advisory_agent_role_name" {
  description = "Name of the Advisory Agent Lambda execution role"
  value       = aws_iam_role.advisory_agent.name
}

output "order_manager_role_arn" {
  description = "ARN of the Order Manager Lambda execution role"
  value       = aws_iam_role.order_manager.arn
}

output "order_manager_role_name" {
  description = "Name of the Order Manager Lambda execution role"
  value       = aws_iam_role.order_manager.name
}

output "wallet_service_role_arn" {
  description = "ARN of the Wallet Service Lambda execution role"
  value       = aws_iam_role.wallet_service.arn
}

output "wallet_service_role_name" {
  description = "Name of the Wallet Service Lambda execution role"
  value       = aws_iam_role.wallet_service.name
}

# ---------------------------------------------------------
# ALL ROLE ARNs MAP (for cross-module reference)
# ---------------------------------------------------------

output "role_arns" {
  description = "Map of all service role ARNs for cross-module wiring"
  value = {
    market_data_lambda = aws_iam_role.market_data_lambda.arn
    etl_glue           = aws_iam_role.etl_glue.arn
    advisory_agent     = aws_iam_role.advisory_agent.arn
    order_manager      = aws_iam_role.order_manager.arn
    wallet_service     = aws_iam_role.wallet_service.arn
  }
}

output "policy_arns" {
  description = "Map of all service policy ARNs"
  value = {
    market_data_lambda = aws_iam_policy.market_data_lambda.arn
    etl_glue           = aws_iam_policy.etl_glue.arn
    advisory_agent     = aws_iam_policy.advisory_agent.arn
    order_manager      = aws_iam_policy.order_manager.arn
    wallet_service     = aws_iam_policy.wallet_service.arn
  }
}
