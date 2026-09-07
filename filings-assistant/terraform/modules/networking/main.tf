# ===========================================================================
# Networking module: a VPC with private subnets across two AZs.
#
# LEARNING NOTE: A VPC is your own isolated network in AWS. The data services
# (OpenSearch, RDS) live in PRIVATE subnets (no direct internet route) for
# security. Lambda runs in these subnets too. We keep it deliberately simple
# for dev — no NAT Gateway (which costs ~$32/mo) — and rely on VPC endpoints /
# public managed-service endpoints as needed.
# ===========================================================================

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "tags" {
  description = "Common tags applied to resources."
  type        = map(string)
  default     = {}
}

# Look up which Availability Zones exist in the current region.
data "aws_availability_zones" "available" {
  state = "available"
}

# The VPC itself.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# Two private subnets, one per AZ. `cidrsubnet` carves /24s out of the VPC CIDR.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-private-${count.index}" })
}

# A security group for Lambda: allow all outbound so it can reach OpenSearch /
# RDS / AWS APIs. Inbound is not needed (Lambda is invoked, not connected to).
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Security group for the indexing worker Lambda"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-lambda-sg" })
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}
