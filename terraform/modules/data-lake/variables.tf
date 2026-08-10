# Data Lake Module Variables
# VerticalBroker AWS Data Engineering Platform
#
# Input variables for all data-lake module components:
#   - S3 buckets (Bronze/Silver/Gold/Regulatory Store)
#   - Lifecycle policies (Intelligent-Tiering, Glacier Deep Archive)
#   - Encryption (KMS CMKs per classification)
#   - Cross-region replication (DR)
#   - Glue Data Catalog (databases, tables, crawlers)
#   - Lake Formation (column-level access controls)
#
# Requirements: 2.1-2.6, 13.5, 14.1, 14.4, 16.3

# ---------------------------------------------------------
# ENVIRONMENT & ACCOUNT CONFIGURATION
# ---------------------------------------------------------

variable "environment" {
  description = "Deployment environment (dev, staging, production, dr)"
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
}

variable "aws_account_id" {
  description = "Target AWS account ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number."
  }
}

variable "name_prefix" {
  description = "Prefix for all resource names: {platform}-{environment}"
  type        = string
}

variable "platform_name" {
  description = "Platform identifier used in resource naming"
  type        = string
  default     = "verticalbroker"
}

# ---------------------------------------------------------
# S3 BUCKET NAMING OVERRIDES
# Default names follow convention: vb-{layer}-{environment}
# ---------------------------------------------------------

variable "bronze_bucket_name" {
  description = "Override name for the Bronze layer S3 bucket (default: vb-bronze-{env})"
  type        = string
  default     = ""
}

variable "silver_bucket_name" {
  description = "Override name for the Silver layer S3 bucket (default: vb-silver-{env})"
  type        = string
  default     = ""
}

variable "gold_bucket_name" {
  description = "Override name for the Gold layer S3 bucket (default: vb-gold-{env})"
  type        = string
  default     = ""
}

variable "regulatory_bucket_name" {
  description = "Override name for the Regulatory Store S3 bucket (default: vb-regulatory-store-{env})"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# KMS KEY ARNS (from Security module)
# Requirement 2.5, 14.1: Separate CMKs per classification level
# ---------------------------------------------------------

variable "kms_confidential_key_arn" {
  description = "KMS CMK ARN for Confidential data classification (Bronze/Silver/Gold layers)"
  type        = string
}

variable "kms_restricted_key_arn" {
  description = "KMS CMK ARN for Restricted data classification (Regulatory Store - PII/audit)"
  type        = string
}

variable "kms_confidential_dr_key_arn" {
  description = "KMS replica key ARN for Confidential data in DR region"
  type        = string
  default     = ""
}

variable "kms_internal_key_arn" {
  description = "KMS CMK ARN for Internal data (Terraform state) in primary region"
  type        = string
  default     = ""
}

variable "kms_internal_dr_key_arn" {
  description = "KMS replica key ARN for Internal data in DR region"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# LIFECYCLE CONFIGURATION
# Requirement 2.2: Intelligent-Tiering and Glacier Deep Archive
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

variable "bronze_intelligent_tiering_days" {
  description = "Days before Bronze data transitions to Intelligent-Tiering storage class"
  type        = number
  default     = 0

  validation {
    condition     = var.bronze_intelligent_tiering_days >= 0
    error_message = "Intelligent-Tiering transition must be 0 or more days."
  }
}

variable "silver_intelligent_tiering_days" {
  description = "Days before Silver data transitions to Intelligent-Tiering"
  type        = number
  default     = 30
}

variable "gold_intelligent_tiering_days" {
  description = "Days before Gold data transitions to Intelligent-Tiering"
  type        = number
  default     = 60
}

variable "noncurrent_version_expiration_days" {
  description = "Days before noncurrent versions are expired"
  type        = number
  default     = 365
}

# ---------------------------------------------------------
# OBJECT LOCK CONFIGURATION
# Requirement 2.3: Governance mode on Bronze
# Requirement 14.4: COMPLIANCE mode on Regulatory Store, 7-year retention
# ---------------------------------------------------------

variable "bronze_object_lock_retention_days" {
  description = "Object Lock retention period in days for Bronze bucket (Governance mode)"
  type        = number
  default     = 90

  validation {
    condition     = var.bronze_object_lock_retention_days >= 1
    error_message = "Object Lock retention must be at least 1 day."
  }
}

variable "regulatory_retention_years" {
  description = "FINRA 4511 regulatory data retention in years (Requirement 14.4: 7 years minimum)"
  type        = number
  default     = 7

  validation {
    condition     = var.regulatory_retention_years >= 7
    error_message = "Regulatory retention must be at least 7 years per FINRA Rule 4511."
  }
}

# ---------------------------------------------------------
# CROSS-REGION REPLICATION (Requirements 2.6, 16.3)
# ---------------------------------------------------------

variable "enable_cross_region_replication" {
  description = "Enable S3 Cross-Region Replication to DR region"
  type        = bool
  default     = false
}

variable "dr_region" {
  description = "Disaster recovery AWS region for cross-region replication"
  type        = string
  default     = "us-west-2"
}

variable "terraform_state_bucket_id" {
  description = "ID (name) of the Terraform state S3 bucket (source for replication)"
  type        = string
  default     = ""
}

variable "terraform_state_bucket_arn" {
  description = "ARN of the Terraform state S3 bucket (source for replication)"
  type        = string
  default     = ""
}

variable "monitoring_sns_topic_arn" {
  description = "SNS topic ARN for replication lag alarm notifications"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# IAM ROLE ARNs (from Security module - used by Glue/Lake Formation)
# ---------------------------------------------------------

variable "etl_glue_role_arn" {
  description = "ARN of the ETL Glue job execution role"
  type        = string
  default     = ""
}

variable "market_data_lambda_role_arn" {
  description = "ARN of the Market Data Lambda execution role"
  type        = string
  default     = ""
}

variable "analyst_role_arn" {
  description = "ARN of the Analyst IAM role for read-only data access"
  type        = string
  default     = ""
}

variable "compliance_role_arn" {
  description = "ARN of the Compliance IAM role with full PII access for regulatory reporting"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# GLUE JOB CONFIGURATION
# Requirements: 3.7, 4.6, 17.4
# ---------------------------------------------------------

variable "glue_subnet_id" {
  description = "Subnet ID for Glue connection (private data subnet)"
  type        = string
  default     = ""
}

variable "glue_security_group_ids" {
  description = "Security group IDs for Glue connection (VPC access)"
  type        = list(string)
  default     = []
}

variable "glue_connection_availability_zone" {
  description = "Availability zone for Glue VPC connection"
  type        = string
  default     = ""
}

variable "event_bus_name" {
  description = "EventBridge event bus name for pipeline events"
  type        = string
  default     = "verticalbroker-platform"
}

# ---------------------------------------------------------
# LAKE FORMATION CONFIGURATION
# ---------------------------------------------------------

variable "lake_formation_admin_arns" {
  description = "List of IAM principal ARNs designated as Lake Formation administrators"
  type        = list(string)
  default     = []
}

variable "lake_formation_service_role_arn" {
  description = "IAM role ARN for Lake Formation service to access S3 locations"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# MANDATORY TAGS (Requirement 13.5)
# ---------------------------------------------------------

variable "mandatory_tags" {
  description = "Mandatory tags applied to all resources (Environment, Service, Owner, CostCenter, DataClassification, Compliance)"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
