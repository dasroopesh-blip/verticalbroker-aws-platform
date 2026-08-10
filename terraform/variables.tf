# Root Variables Definition
# VerticalBroker AWS Data Engineering Platform
# Requirements: 13.5 (Mandatory tags: Environment, Service, Owner, CostCenter,
#               DataClassification, Compliance)
# Requirements: 13.2 (Multi-account deployment across environments)
# Requirements: 13.8 (Parameterized by account ID and organizational unit)

# ---------------------------------------------------------
# ENVIRONMENT IDENTIFICATION
# ---------------------------------------------------------

variable "environment" {
  description = "Deployment environment identifier (dev, staging, production, dr)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production", "dr"], var.environment)
    error_message = "Environment must be one of: dev, staging, production, dr."
  }
}

variable "aws_region" {
  description = "Primary AWS region for resource deployment"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "AWS region must be a valid region identifier (e.g., us-east-1)."
  }
}

variable "aws_account_id" {
  description = "Target AWS account ID for deployment (supports 100+ account scaling)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number."
  }
}

variable "organizational_unit" {
  description = "AWS Organizations OU for this deployment (Security, SharedServices, DataLake, Compute, DR)"
  type        = string

  validation {
    condition     = contains(["Security", "SharedServices", "DataLake", "Compute", "DR"], var.organizational_unit)
    error_message = "Organizational unit must be one of: Security, SharedServices, DataLake, Compute, DR."
  }
}

variable "dr_region" {
  description = "Disaster recovery AWS region for cross-region replication"
  type        = string
  default     = "us-west-2"
}

# ---------------------------------------------------------
# MANDATORY TAGS (Requirement 13.5)
# All resources MUST have these tags applied
# ---------------------------------------------------------

variable "tag_environment" {
  description = "Mandatory tag: Environment (dev, staging, production, dr)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production", "dr"], var.tag_environment)
    error_message = "Tag Environment must be one of: dev, staging, production, dr."
  }
}

variable "tag_service" {
  description = "Mandatory tag: Service name identifying the platform component"
  type        = string

  validation {
    condition     = length(var.tag_service) > 0 && length(var.tag_service) <= 128
    error_message = "Tag Service must be a non-empty string with max 128 characters."
  }
}

variable "tag_owner" {
  description = "Mandatory tag: Team or individual responsible for the resource"
  type        = string

  validation {
    condition     = length(var.tag_owner) > 0 && length(var.tag_owner) <= 128
    error_message = "Tag Owner must be a non-empty string with max 128 characters."
  }
}

variable "tag_cost_center" {
  description = "Mandatory tag: Cost center code for financial allocation and chargeback"
  type        = string

  validation {
    condition     = can(regex("^[A-Z]{2,4}-[0-9]{3,6}$", var.tag_cost_center))
    error_message = "Tag CostCenter must match pattern XX-NNN (e.g., DE-001)."
  }
}

variable "tag_data_classification" {
  description = "Mandatory tag: Data classification level per security policy"
  type        = string

  validation {
    condition     = contains(["Public", "Internal", "Confidential", "Restricted"], var.tag_data_classification)
    error_message = "Tag DataClassification must be one of: Public, Internal, Confidential, Restricted."
  }
}

variable "tag_compliance" {
  description = "Mandatory tag: Applicable compliance framework(s)"
  type        = string

  validation {
    condition     = length(var.tag_compliance) > 0
    error_message = "Tag Compliance must be a non-empty string (e.g., FINRA-4511, SOC2-TypeII)."
  }
}

# ---------------------------------------------------------
# COMPUTED MANDATORY TAGS MAP
# ---------------------------------------------------------

variable "mandatory_tags" {
  description = "Complete map of mandatory tags applied to all resources. If provided, overrides individual tag variables."
  type        = map(string)
  default     = {}

  validation {
    condition = length(var.mandatory_tags) == 0 || alltrue([
      for key in ["Environment", "Service", "Owner", "CostCenter", "DataClassification", "Compliance"] :
      contains(keys(var.mandatory_tags), key)
    ])
    error_message = "If mandatory_tags is provided, it must contain all required keys: Environment, Service, Owner, CostCenter, DataClassification, Compliance."
  }
}

# ---------------------------------------------------------
# PLATFORM CONFIGURATION
# ---------------------------------------------------------

variable "platform_name" {
  description = "Platform identifier used in resource naming"
  type        = string
  default     = "verticalbroker"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.platform_name))
    error_message = "Platform name must be lowercase alphanumeric with hyphens, 3-31 characters."
  }
}

variable "enable_cross_region_replication" {
  description = "Enable cross-region replication for DR (Requirement 16.3)"
  type        = bool
  default     = false
}

variable "enable_multi_az" {
  description = "Deploy across multiple availability zones (Requirement 16.1)"
  type        = bool
  default     = true
}

variable "min_availability_zones" {
  description = "Minimum number of AZs for HA deployment (Requirement 16.1: minimum 3)"
  type        = number
  default     = 3

  validation {
    condition     = var.min_availability_zones >= 2 && var.min_availability_zones <= 6
    error_message = "Minimum availability zones must be between 2 and 6."
  }
}

# ---------------------------------------------------------
# NETWORKING VARIABLES
# ---------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid CIDR block."
  }
}

variable "enable_transit_gateway" {
  description = "Enable Transit Gateway attachment for cross-account connectivity"
  type        = bool
  default     = true
}

# ---------------------------------------------------------
# COMPUTE SCALING VARIABLES
# ---------------------------------------------------------

variable "lambda_reserved_concurrency_trade" {
  description = "Reserved concurrency for trade processing Lambda (Requirement 7.4)"
  type        = number
  default     = 1000

  validation {
    condition     = var.lambda_reserved_concurrency_trade >= 1
    error_message = "Lambda reserved concurrency must be at least 1."
  }
}

variable "lambda_reserved_concurrency_advisory" {
  description = "Reserved concurrency for advisory Lambda (Requirement 7.4)"
  type        = number
  default     = 500

  validation {
    condition     = var.lambda_reserved_concurrency_advisory >= 1
    error_message = "Lambda reserved concurrency must be at least 1."
  }
}

variable "lambda_reserved_concurrency_ingestion" {
  description = "Reserved concurrency for ingestion Lambda (Requirement 7.4)"
  type        = number
  default     = 2000

  validation {
    condition     = var.lambda_reserved_concurrency_ingestion >= 1
    error_message = "Lambda reserved concurrency must be at least 1."
  }
}

variable "glue_max_dpus" {
  description = "Maximum Glue DPUs for auto-scaling ETL (Requirement 3.7: max 100)"
  type        = number
  default     = 100

  validation {
    condition     = var.glue_max_dpus >= 2 && var.glue_max_dpus <= 300
    error_message = "Glue max DPUs must be between 2 and 300."
  }
}

# ---------------------------------------------------------
# DATA RETENTION VARIABLES
# ---------------------------------------------------------

variable "bronze_glacier_transition_days" {
  description = "Days before Bronze data transitions to Glacier Deep Archive (Requirement 2.2: 90 days)"
  type        = number
  default     = 90

  validation {
    condition     = var.bronze_glacier_transition_days >= 1
    error_message = "Glacier transition must be at least 1 day."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days (Requirement 15.6: 90 days)"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2556, 3653], var.log_retention_days)
    error_message = "Log retention must be a valid CloudWatch retention period."
  }
}

variable "regulatory_retention_years" {
  description = "FINRA 4511 regulatory data retention in years (Requirement 14.4: 7 years)"
  type        = number
  default     = 7

  validation {
    condition     = var.regulatory_retention_years >= 7
    error_message = "Regulatory retention must be at least 7 years per FINRA Rule 4511."
  }
}
