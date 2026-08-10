# Networking Module - VPC and Subnets
# VerticalBroker AWS Data Engineering Platform
#
# Implements Production VPC (10.0.0.0/16) with 6 private subnets across 3 AZs:
# - Data Subnets: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24
# - Compute Subnets: 10.0.4.0/24, 10.0.5.0/24, 10.0.6.0/24
#
# Requirements: 20.2 (Transit Gateway, inter-account connectivity)
#               20.3 (Private subnets, no direct internet access, VPC Endpoints)
#               16.1 (Minimum 3 AZs)

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------
# DATA SOURCES
# ---------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Select the required number of AZs (Requirement 16.1: minimum 3)
  azs = slice(data.aws_availability_zones.available.names, 0, var.min_availability_zones)

  # Subnet naming
  data_subnet_names    = [for i, az in local.azs : "${var.name_prefix}-data-${az}"]
  compute_subnet_names = [for i, az in local.azs : "${var.name_prefix}-compute-${az}"]

  # Combined subnet IDs for route table association
  all_subnet_ids = concat(
    aws_subnet.data[*].id,
    aws_subnet.compute[*].id
  )
}

# ---------------------------------------------------------
# VPC
# Production VPC: 10.0.0.0/16
# No Internet Gateway - all traffic stays private (Requirement 20.3)
# ---------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required for VPC endpoints
  instance_tenancy = "default"

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpc"
    Purpose = "Production VPC for VerticalBroker data platform"
  })
}

# ---------------------------------------------------------
# PRIVATE SUBNETS - DATA TIER
# Data subnets for S3-backed services (Glue, DMS, Lake Formation)
# Spread across 3 AZs for high availability (Requirement 16.1)
# ---------------------------------------------------------

resource "aws_subnet" "data" {
  count = var.min_availability_zones

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.data_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # Private subnet - no public IPs (Requirement 20.3)

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-data-${local.azs[count.index]}"
    Tier    = "data"
    Purpose = "Data tier - S3, Glue, DMS, Lake Formation access"
  })
}

# ---------------------------------------------------------
# PRIVATE SUBNETS - COMPUTE TIER
# Compute subnets for Lambda, Step Functions, API Gateway
# Spread across 3 AZs for high availability (Requirement 16.1)
# ---------------------------------------------------------

resource "aws_subnet" "compute" {
  count = var.min_availability_zones

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.compute_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # Private subnet - no public IPs (Requirement 20.3)

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-compute-${local.azs[count.index]}"
    Tier    = "compute"
    Purpose = "Compute tier - Lambda, Step Functions, API Gateway"
  })
}

# ---------------------------------------------------------
# ROUTE TABLES
# Separate route tables for data and compute tiers
# No route to Internet Gateway (Requirement 20.3)
# ---------------------------------------------------------

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-rt-data"
    Tier    = "data"
    Purpose = "Route table for data tier subnets"
  })
}

resource "aws_route_table" "compute" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-rt-compute"
    Tier    = "compute"
    Purpose = "Route table for compute tier subnets"
  })
}

# Associate data subnets with data route table
resource "aws_route_table_association" "data" {
  count = var.min_availability_zones

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# Associate compute subnets with compute route table
resource "aws_route_table_association" "compute" {
  count = var.min_availability_zones

  subnet_id      = aws_subnet.compute[count.index].id
  route_table_id = aws_route_table.compute.id
}

# ---------------------------------------------------------
# NETWORK ACCESS CONTROL LISTS (NACLs)
# Deny-by-default with explicit allow rules (Requirement 20.6)
# ---------------------------------------------------------

resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.data[*].id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-nacl-data"
    Tier    = "data"
    Purpose = "NACL for data tier - deny-by-default"
  })
}

# Allow inbound traffic from VPC CIDR (inter-subnet communication)
resource "aws_network_acl_rule" "data_inbound_vpc" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Allow inbound ephemeral ports for return traffic from VPC endpoints
resource "aws_network_acl_rule" "data_inbound_ephemeral" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Allow all outbound traffic within VPC
resource "aws_network_acl_rule" "data_outbound_vpc" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Allow outbound HTTPS for VPC endpoint communication
resource "aws_network_acl_rule" "data_outbound_https" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Deny all other inbound traffic (implicit deny, but explicit for documentation)
resource "aws_network_acl_rule" "data_deny_all_inbound" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 32766
  egress         = false
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
}

# Deny all other outbound traffic (explicit deny)
resource "aws_network_acl_rule" "data_deny_all_outbound" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 32766
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl" "compute" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.compute[*].id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-nacl-compute"
    Tier    = "compute"
    Purpose = "NACL for compute tier - deny-by-default"
  })
}

# Allow inbound traffic from VPC CIDR (inter-subnet communication)
resource "aws_network_acl_rule" "compute_inbound_vpc" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Allow inbound ephemeral ports for return traffic
resource "aws_network_acl_rule" "compute_inbound_ephemeral" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Allow all outbound traffic within VPC
resource "aws_network_acl_rule" "compute_outbound_vpc" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
}

# Allow outbound HTTPS for VPC endpoint and AWS service communication
resource "aws_network_acl_rule" "compute_outbound_https" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Deny all other inbound traffic
resource "aws_network_acl_rule" "compute_deny_all_inbound" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 32766
  egress         = false
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
}

# Deny all other outbound traffic
resource "aws_network_acl_rule" "compute_deny_all_outbound" {
  network_acl_id = aws_network_acl.compute.id
  rule_number    = 32766
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
}

# ---------------------------------------------------------
# VPC FLOW LOGS
# Network traffic monitoring for security and compliance
# ---------------------------------------------------------

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  iam_role_arn    = aws_iam_role.flow_log[0].arn
  log_destination = aws_cloudwatch_log_group.flow_log[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-flow-log"
    Purpose = "VPC Flow Logs for network monitoring"
  })
}

resource "aws_cloudwatch_log_group" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/flow-log/${var.name_prefix}"
  retention_in_days = var.flow_log_retention_days

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-flow-log-group"
    Purpose = "VPC Flow Logs storage"
  })
}

resource "aws_iam_role" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.name_prefix}-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-flow-log-role"
    Purpose = "IAM role for VPC Flow Logs delivery"
  })
}

resource "aws_iam_role_policy" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.name_prefix}-flow-log-policy"
  role = aws_iam_role.flow_log[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "${aws_cloudwatch_log_group.flow_log[0].arn}:*"
      }
    ]
  })
}
