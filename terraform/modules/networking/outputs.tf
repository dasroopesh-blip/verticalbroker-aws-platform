# Networking Module Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exports VPC, subnet, Transit Gateway, endpoint, and security group identifiers
# for consumption by other modules (compute, data-lake, analytics, security, ml).

# ---------------------------------------------------------
# VPC OUTPUTS
# ---------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "vpc_arn" {
  description = "ARN of the VPC"
  value       = aws_vpc.main.arn
}

# ---------------------------------------------------------
# SUBNET OUTPUTS
# ---------------------------------------------------------

output "data_subnet_ids" {
  description = "List of data tier subnet IDs (across 3 AZs)"
  value       = aws_subnet.data[*].id
}

output "data_subnet_cidrs" {
  description = "List of data tier subnet CIDR blocks"
  value       = aws_subnet.data[*].cidr_block
}

output "data_subnet_arns" {
  description = "List of data tier subnet ARNs"
  value       = aws_subnet.data[*].arn
}

output "compute_subnet_ids" {
  description = "List of compute tier subnet IDs (across 3 AZs)"
  value       = aws_subnet.compute[*].id
}

output "compute_subnet_cidrs" {
  description = "List of compute tier subnet CIDR blocks"
  value       = aws_subnet.compute[*].cidr_block
}

output "compute_subnet_arns" {
  description = "List of compute tier subnet ARNs"
  value       = aws_subnet.compute[*].arn
}

output "all_subnet_ids" {
  description = "All subnet IDs (data + compute) for VPC-wide operations"
  value       = local.all_subnet_ids
}

output "availability_zones" {
  description = "List of availability zones used for subnet placement"
  value       = local.azs
}

# ---------------------------------------------------------
# ROUTE TABLE OUTPUTS
# ---------------------------------------------------------

output "data_route_table_id" {
  description = "ID of the data tier route table"
  value       = aws_route_table.data.id
}

output "compute_route_table_id" {
  description = "ID of the compute tier route table"
  value       = aws_route_table.compute.id
}

# ---------------------------------------------------------
# TRANSIT GATEWAY OUTPUTS
# ---------------------------------------------------------

output "transit_gateway_id" {
  description = "ID of the Transit Gateway (empty if disabled)"
  value       = var.enable_transit_gateway ? local.transit_gateway_id : ""
}

output "transit_gateway_arn" {
  description = "ARN of the Transit Gateway (empty if disabled)"
  value       = var.enable_transit_gateway && var.transit_gateway_id == "" ? aws_ec2_transit_gateway.main[0].arn : ""
}

output "transit_gateway_vpc_attachment_id" {
  description = "ID of the production VPC TGW attachment"
  value       = var.enable_transit_gateway ? aws_ec2_transit_gateway_vpc_attachment.production[0].id : ""
}

output "transit_gateway_route_table_production_id" {
  description = "ID of the production TGW route table"
  value       = var.enable_transit_gateway && var.transit_gateway_id == "" ? aws_ec2_transit_gateway_route_table.production[0].id : ""
}

output "transit_gateway_route_table_non_production_id" {
  description = "ID of the non-production TGW route table"
  value       = var.enable_transit_gateway && var.transit_gateway_id == "" ? aws_ec2_transit_gateway_route_table.non_production[0].id : ""
}

output "transit_gateway_route_table_shared_services_id" {
  description = "ID of the shared services TGW route table"
  value       = var.enable_transit_gateway && var.transit_gateway_id == "" ? aws_ec2_transit_gateway_route_table.shared_services[0].id : ""
}

output "transit_gateway_ram_share_arn" {
  description = "ARN of the RAM resource share for TGW"
  value       = var.enable_transit_gateway && var.transit_gateway_id == "" ? aws_ram_resource_share.tgw[0].arn : ""
}

# ---------------------------------------------------------
# VPC ENDPOINT OUTPUTS
# ---------------------------------------------------------

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 Gateway VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.s3[0].id : ""
}

output "vpc_endpoint_s3_prefix_list_id" {
  description = "Prefix list ID of the S3 Gateway VPC Endpoint (for security group rules)"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.s3[0].prefix_list_id : ""
}

output "vpc_endpoint_glue_id" {
  description = "ID of the Glue Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.glue[0].id : ""
}

output "vpc_endpoint_kms_id" {
  description = "ID of the KMS Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.kms[0].id : ""
}

output "vpc_endpoint_sqs_id" {
  description = "ID of the SQS Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.sqs[0].id : ""
}

output "vpc_endpoint_events_id" {
  description = "ID of the EventBridge Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.events[0].id : ""
}

output "vpc_endpoint_logs_id" {
  description = "ID of the CloudWatch Logs Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.logs[0].id : ""
}

output "vpc_endpoint_monitoring_id" {
  description = "ID of the CloudWatch Monitoring Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.monitoring[0].id : ""
}

output "vpc_endpoint_execute_api_id" {
  description = "ID of the API Gateway execute-api PrivateLink Endpoint"
  value       = var.enable_privatelink_api_gateway ? aws_vpc_endpoint.execute_api[0].id : ""
}

output "vpc_endpoint_dynamodb_id" {
  description = "ID of the DynamoDB Gateway VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.dynamodb[0].id : ""
}

output "vpc_endpoint_sts_id" {
  description = "ID of the STS Interface VPC Endpoint"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.sts[0].id : ""
}

# ---------------------------------------------------------
# SECURITY GROUP OUTPUTS
# ---------------------------------------------------------

output "security_group_vpc_endpoints_id" {
  description = "Security group ID for VPC Interface Endpoints"
  value       = var.enable_vpc_endpoints ? aws_security_group.vpc_endpoints[0].id : ""
}

output "security_group_api_gateway_endpoint_id" {
  description = "Security group ID for API Gateway PrivateLink Endpoint"
  value       = var.enable_privatelink_api_gateway ? aws_security_group.api_gateway_endpoint[0].id : ""
}

output "security_group_data_tier_id" {
  description = "Security group ID for data tier services (Glue, DMS, Lake Formation)"
  value       = aws_security_group.data_tier.id
}

output "security_group_compute_tier_id" {
  description = "Security group ID for compute tier services (Lambda, Step Functions)"
  value       = aws_security_group.compute_tier.id
}

output "security_group_analytics_tier_id" {
  description = "Security group ID for analytics services (OpenSearch, Neptune, Athena)"
  value       = aws_security_group.analytics_tier.id
}

output "security_group_database_tier_id" {
  description = "Security group ID for database services (Neptune)"
  value       = aws_security_group.database_tier.id
}

output "security_group_streaming_tier_id" {
  description = "Security group ID for streaming services (Kinesis, DMS)"
  value       = aws_security_group.streaming_tier.id
}

output "security_group_ml_tier_id" {
  description = "Security group ID for ML services (SageMaker)"
  value       = aws_security_group.ml_tier.id
}

# ---------------------------------------------------------
# NACL OUTPUTS
# ---------------------------------------------------------

output "nacl_data_id" {
  description = "ID of the data tier Network ACL"
  value       = aws_network_acl.data.id
}

output "nacl_compute_id" {
  description = "ID of the compute tier Network ACL"
  value       = aws_network_acl.compute.id
}

# ---------------------------------------------------------
# FLOW LOG OUTPUTS
# ---------------------------------------------------------

output "flow_log_id" {
  description = "ID of the VPC Flow Log"
  value       = var.enable_flow_logs ? aws_flow_log.vpc[0].id : ""
}

output "flow_log_group_arn" {
  description = "ARN of the CloudWatch Log Group for VPC Flow Logs"
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_log[0].arn : ""
}
