# Security Module Variables
# VerticalBroker AWS Data Engineering Platform
# Requirements: 14.1 (Separate KMS keys per classification)
# Requirements: 14.3 (Least-privilege IAM), 13.4 (No wildcard resources), 20.5 (Baseline security)
# Requirements: 2.5 (Annual key rotation)

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

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "AWS region must be a valid region identifier."
  }
}

variable "aws_account_id" {
  description = "Target AWS account ID for IAM resource ARN construction"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number."
  }
}

variable "platform_name" {
  description = "Platform identifier used in resource naming"
  type        = string
  default     = "verticalbroker"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.platform_name))
    error_message = "Platform name must be lowercase alphanumeric with hyphens, 3-31 characters."
  }
}

variable "name_prefix" {
  description = "Prefix for all resource names: {platform}-{environment}"
  type        = string
}

# ---------------------------------------------------------
# KMS KEY CONFIGURATION (Requirement 14.1, 2.5)
# ---------------------------------------------------------

variable "dr_region" {
  description = "Disaster recovery region for cross-region key replication (Requirement 16.3)"
  type        = string
  default     = "us-west-2"
}

variable "enable_cross_region_replication" {
  description = "Enable cross-region KMS key replication for DR"
  type        = bool
  default     = false
}

variable "data_classifications" {
  description = "Data classification levels requiring separate CMKs (Requirement 14.1)"
  type        = list(string)
  default     = ["Public", "Internal", "Confidential", "Restricted"]

  validation {
    condition     = length(var.data_classifications) > 0
    error_message = "At least one data classification level must be specified."
  }
}

variable "service_role_arns" {
  description = "Map of service role ARNs that require KMS access, grouped by classification level"
  type        = map(list(string))
  default     = {}
}

variable "admin_role_arns" {
  description = "IAM role ARNs granted KMS key administration permissions"
  type        = list(string)
  default     = []
}

variable "enable_key_rotation" {
  description = "Enable automatic annual key rotation on all CMKs (Requirement 2.5)"
  type        = bool
  default     = true
}

variable "key_deletion_window_in_days" {
  description = "Waiting period (days) before KMS key deletion. Minimum 7, maximum 30."
  type        = number
  default     = 30

  validation {
    condition     = var.key_deletion_window_in_days >= 7 && var.key_deletion_window_in_days <= 30
    error_message = "Key deletion window must be between 7 and 30 days."
  }
}

variable "mandatory_tags" {
  description = "Mandatory tags applied to all resources (Requirement 13.5)"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------
# KMS KEY ARNs (from KMS module - used by IAM roles)
# ---------------------------------------------------------

variable "kms_bronze_key_arn" {
  description = "ARN of the KMS key for Bronze layer encryption"
  type        = string
  default     = ""
}

variable "kms_silver_key_arn" {
  description = "ARN of the KMS key for Silver layer encryption"
  type        = string
  default     = ""
}

variable "kms_gold_key_arn" {
  description = "ARN of the KMS key for Gold layer encryption"
  type        = string
  default     = ""
}

variable "kms_restricted_key_arn" {
  description = "ARN of the KMS key for Restricted/PII data encryption"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# RESOURCE IDENTIFIERS (for policy ARN construction)
# ---------------------------------------------------------

variable "kinesis_market_data_stream_name" {
  description = "Name of the Kinesis market data stream"
  type        = string
  default     = "vb-market-data"
}

variable "eventbridge_bus_name" {
  description = "Name of the EventBridge event bus"
  type        = string
  default     = "verticalbroker-platform"
}

variable "sagemaker_advisory_endpoint_prefix" {
  description = "Prefix for SageMaker advisory endpoint names"
  type        = string
  default     = "vb-advisory"
}

# ---------------------------------------------------------
# MANDATORY TAGS (Requirement 13.5)
# ---------------------------------------------------------

variable "tags" {
  description = "Mandatory tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------
# SECURITY DETECTION & AUDIT (Requirements 14.5, 14.6, 14.8, 20.5)
# ---------------------------------------------------------

variable "security_account_id" {
  description = "Delegated Security & Audit account ID for cross-account log delivery"
  type        = string
  default     = ""
}

variable "enable_guardduty" {
  description = "Enable per-account GuardDuty detector with S3 data source"
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Enable per-account Security Hub with FSBP and CIS standards"
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Enable per-environment CloudTrail for data events"
  type        = bool
  default     = true
}

variable "enable_config_rules" {
  description = "Enable AWS Config conformance packs for compliance rules"
  type        = bool
  default     = true
}

variable "cloudtrail_s3_bucket_name" {
  description = "S3 bucket name for per-environment CloudTrail logs (in security account)"
  type        = string
  default     = ""
}

variable "cloudtrail_kms_key_arn" {
  description = "KMS key ARN for CloudTrail log encryption"
  type        = string
  default     = ""
}

variable "guardduty_threat_intel_set_url" {
  description = "URL of a custom threat intelligence feed in STIX format (optional)"
  type        = string
  default     = ""
}

variable "security_notification_topic_arn" {
  description = "SNS topic ARN for security alert notifications"
  type        = string
  default     = ""
}

variable "data_bucket_arns" {
  description = "List of S3 bucket ARNs to monitor with CloudTrail data events"
  type        = list(string)
  default     = []
}

variable "lambda_function_arns" {
  description = "List of Lambda function ARNs to monitor with CloudTrail data events"
  type        = list(string)
  default     = []
}

variable "dynamodb_table_arns" {
  description = "List of DynamoDB table ARNs to monitor with CloudTrail data events"
  type        = list(string)
  default     = []
}

variable "required_tags" {
  description = "Map of required tag keys for Config compliance checking"
  type        = map(string)
  default = {
    tag1Key = "Environment"
    tag2Key = "Service"
    tag3Key = "Owner"
    tag4Key = "CostCenter"
    tag5Key = "DataClassification"
    tag6Key = "Compliance"
  }
}

variable "vpc_ids" {
  description = "VPC IDs to check for flow log enablement"
  type        = list(string)
  default     = []
}
