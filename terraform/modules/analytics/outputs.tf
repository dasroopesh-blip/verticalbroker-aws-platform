# Analytics Module - Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exposes endpoints, identifiers, and ARNs for cross-module references.
# Requirements: 9, 10, 11 (Search, Graph, SQL Analytics)

# ---------------------------------------------------------
# OPENSEARCH OUTPUTS (Requirement 9)
# ---------------------------------------------------------

output "opensearch_domain_arn" {
  description = "ARN of the OpenSearch domain"
  value       = aws_opensearch_domain.main.arn
}

output "opensearch_domain_id" {
  description = "Unique identifier for the OpenSearch domain"
  value       = aws_opensearch_domain.main.domain_id
}

output "opensearch_domain_name" {
  description = "Name of the OpenSearch domain"
  value       = aws_opensearch_domain.main.domain_name
}

output "opensearch_domain_endpoint" {
  description = "Domain-specific endpoint for OpenSearch API access (HTTPS)"
  value       = aws_opensearch_domain.main.endpoint
}

output "opensearch_dashboard_endpoint" {
  description = "Domain-specific endpoint for OpenSearch Dashboards"
  value       = aws_opensearch_domain.main.dashboard_endpoint
}

output "opensearch_security_group_id" {
  description = "Security group ID for the OpenSearch domain"
  value       = aws_security_group.opensearch.id
}

output "opensearch_ism_policy_json" {
  description = "Index State Management policy JSON for hot/warm/cold/delete lifecycle"
  value       = local.ism_policy
}

output "opensearch_trade_records_template_json" {
  description = "Index template JSON for trade_records index (12 shards, 2 replicas)"
  value       = local.trade_records_index_template
}

output "opensearch_client_profiles_template_json" {
  description = "Index template JSON for client_profiles index (6 shards, 2 replicas)"
  value       = local.client_profiles_index_template
}

# ---------------------------------------------------------
# NEPTUNE OUTPUTS (Requirement 10)
# ---------------------------------------------------------

output "neptune_cluster_arn" {
  description = "ARN of the Neptune cluster"
  value       = aws_neptune_cluster.main.arn
}

output "neptune_cluster_id" {
  description = "Identifier of the Neptune cluster"
  value       = aws_neptune_cluster.main.cluster_identifier
}

output "neptune_cluster_endpoint" {
  description = "Writer endpoint for the Neptune cluster (Gremlin queries)"
  value       = aws_neptune_cluster.main.endpoint
}

output "neptune_cluster_reader_endpoint" {
  description = "Reader endpoint for the Neptune cluster (read-only Gremlin queries)"
  value       = aws_neptune_cluster.main.reader_endpoint
}

output "neptune_cluster_port" {
  description = "Port for Gremlin connections to Neptune"
  value       = aws_neptune_cluster.main.port
}

output "neptune_security_group_id" {
  description = "Security group ID for the Neptune cluster"
  value       = aws_security_group.neptune.id
}

output "neptune_loader_role_arn" {
  description = "IAM role ARN for Neptune bulk loader (S3 access to Gold Layer)"
  value       = aws_iam_role.neptune_loader.arn
}

output "neptune_subnet_group_name" {
  description = "Neptune subnet group name"
  value       = aws_neptune_subnet_group.main.name
}

# ---------------------------------------------------------
# ATHENA OUTPUTS (Requirement 11)
# ---------------------------------------------------------

output "athena_workgroup_analytics_name" {
  description = "Name of the analytics Athena workgroup"
  value       = aws_athena_workgroup.analytics.name
}

output "athena_workgroup_analytics_arn" {
  description = "ARN of the analytics Athena workgroup"
  value       = aws_athena_workgroup.analytics.arn
}

output "athena_workgroup_compliance_name" {
  description = "Name of the compliance Athena workgroup"
  value       = aws_athena_workgroup.compliance.name
}

output "athena_workgroup_compliance_arn" {
  description = "ARN of the compliance Athena workgroup"
  value       = aws_athena_workgroup.compliance.arn
}

output "athena_workgroup_data_science_name" {
  description = "Name of the data-science Athena workgroup"
  value       = aws_athena_workgroup.data_science.name
}

output "athena_workgroup_data_science_arn" {
  description = "ARN of the data-science Athena workgroup"
  value       = aws_athena_workgroup.data_science.arn
}

output "athena_results_bucket_name" {
  description = "S3 bucket name for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

output "athena_results_bucket_arn" {
  description = "ARN of the S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.arn
}

output "athena_workgroup_names" {
  description = "Map of all Athena workgroup names for reference"
  value = {
    analytics    = aws_athena_workgroup.analytics.name
    compliance   = aws_athena_workgroup.compliance.name
    data_science = aws_athena_workgroup.data_science.name
  }
}

# ---------------------------------------------------------
# COMBINED OUTPUTS
# ---------------------------------------------------------

output "analytics_endpoints" {
  description = "Map of all analytics service endpoints"
  value = {
    opensearch_endpoint        = aws_opensearch_domain.main.endpoint
    opensearch_dashboard       = aws_opensearch_domain.main.dashboard_endpoint
    neptune_writer_endpoint    = aws_neptune_cluster.main.endpoint
    neptune_reader_endpoint    = aws_neptune_cluster.main.reader_endpoint
    neptune_port               = aws_neptune_cluster.main.port
    athena_results_bucket      = aws_s3_bucket.athena_results.bucket
  }
}

output "analytics_security_group_ids" {
  description = "Map of security group IDs for all analytics services"
  value = {
    opensearch = aws_security_group.opensearch.id
    neptune    = aws_security_group.neptune.id
  }
}
