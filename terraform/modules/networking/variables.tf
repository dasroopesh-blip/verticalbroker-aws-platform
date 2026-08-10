# Networking Module Variables
# VerticalBroker AWS Data Engineering Platform
# Requirements: 20.2, 20.3, 20.4, 20.6, 16.1

# ---------------------------------------------------------
# COMMON MODULE INPUTS
# ---------------------------------------------------------

variable "environment" {
  description = "Deployment environment identifier (dev, staging, production, dr)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production", "dr"], var.environment)
    error_message = "Environment must be one of: dev, staging, production, dr."
  }
}

variable "platform_name" {
  description = "Platform identifier used in resource naming"
  type        = string
  default     = "verticalbroker"
}

variable "name_prefix" {
  description = "Computed prefix for resource naming: {platform}-{environment}"
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "mandatory_tags" {
  description = "Mandatory tags applied to all resources (Requirement 13.5)"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------
# VPC CONFIGURATION
# ---------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the production VPC (Requirement 20.2: 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid CIDR block."
  }
}

variable "min_availability_zones" {
  description = "Minimum number of AZs for deployment (Requirement 16.1: minimum 3)"
  type        = number
  default     = 3

  validation {
    condition     = var.min_availability_zones >= 2 && var.min_availability_zones <= 6
    error_message = "Minimum availability zones must be between 2 and 6."
  }
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for data subnets across AZs (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.data_subnet_cidrs) >= 3
    error_message = "At least 3 data subnet CIDRs must be provided for multi-AZ deployment."
  }
}

variable "compute_subnet_cidrs" {
  description = "CIDR blocks for compute subnets across AZs (one per AZ)"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  validation {
    condition     = length(var.compute_subnet_cidrs) >= 3
    error_message = "At least 3 compute subnet CIDRs must be provided for multi-AZ deployment."
  }
}

# ---------------------------------------------------------
# TRANSIT GATEWAY CONFIGURATION
# ---------------------------------------------------------

variable "enable_transit_gateway" {
  description = "Enable Transit Gateway for cross-account connectivity (Requirement 20.2)"
  type        = bool
  default     = true
}

variable "transit_gateway_id" {
  description = "Existing Transit Gateway ID to attach to (if sharing across accounts). Leave empty to create new."
  type        = string
  default     = ""
}

variable "transit_gateway_asn" {
  description = "BGP ASN for Transit Gateway (must be unique per TGW)"
  type        = number
  default     = 64512

  validation {
    condition     = var.transit_gateway_asn >= 64512 && var.transit_gateway_asn <= 65534
    error_message = "Transit Gateway ASN must be in the private range 64512-65534."
  }
}

variable "non_production_vpc_cidrs" {
  description = "CIDR blocks for non-production VPCs (used for route isolation in TGW)"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------
# VPC ENDPOINT CONFIGURATION
# ---------------------------------------------------------

variable "enable_vpc_endpoints" {
  description = "Enable VPC endpoints for private AWS service access (Requirement 20.3)"
  type        = bool
  default     = true
}

variable "enable_privatelink_api_gateway" {
  description = "Enable PrivateLink for API Gateway private access (Requirement 20.4)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------
# FLOW LOGS CONFIGURATION
# ---------------------------------------------------------

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs for network monitoring"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention period for VPC Flow Logs in CloudWatch (days)"
  type        = number
  default     = 90
}
