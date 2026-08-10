# Analytics Module - Variables
# VerticalBroker AWS Data Engineering Platform
#
# Input variables for OpenSearch, Neptune, and Athena resources.
# Requirements: 9, 10, 11 (Search, Graph, SQL Analytics)

# ---------------------------------------------------------
# COMMON VARIABLES
# ---------------------------------------------------------

variable "environment" {
  description = "Deployment environment (dev, staging, production, dr)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production", "dr"], var.environment)
    error_message = "Environment must be one of: dev, staging, production, dr."
  }
}

variable "platform_name" {
  description = "Platform name used in resource naming"
  type        = string
  default     = "verticalbroker"
}

variable "name_prefix" {
  description = "Prefix for all resource names: {platform}-{environment}"
  type        = string
}

variable "mandatory_tags" {
  description = "Mandatory tags applied to all resources (Environment, Service, Owner, CostCenter, DataClassification, Compliance)"
  type        = map(string)

  validation {
    condition = alltrue([
      contains(keys(var.mandatory_tags), "Environment"),
      contains(keys(var.mandatory_tags), "Service"),
      contains(keys(var.mandatory_tags), "Owner"),
      contains(keys(var.mandatory_tags), "CostCenter"),
    ])
    error_message = "mandatory_tags must include at minimum: Environment, Service, Owner, CostCenter."
  }
}

# ---------------------------------------------------------
# NETWORKING VARIABLES
# ---------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where analytics resources are deployed"
  type        = string
}

variable "data_subnet_ids" {
  description = "List of data subnet IDs (private subnets) for OpenSearch and Neptune deployment"
  type        = list(string)

  validation {
    condition     = length(var.data_subnet_ids) >= 3
    error_message = "At least 3 data subnet IDs required for multi-AZ deployment."
  }
}

variable "compute_subnet_cidrs" {
  description = "CIDR blocks of compute subnets allowed to access analytics services"
  type        = list(string)
}

# ---------------------------------------------------------
# KMS ENCRYPTION
# ---------------------------------------------------------

variable "kms_key_arn" {
  description = "ARN of the KMS CMK for encrypting analytics data at rest"
  type        = string
}

# ---------------------------------------------------------
# OPENSEARCH VARIABLES (Requirement 9)
# ---------------------------------------------------------

variable "opensearch_engine_version" {
  description = "OpenSearch engine version"
  type        = string
  default     = "OpenSearch_2.11"
}

variable "opensearch_access_role_arns" {
  description = "List of IAM role ARNs granted access to the OpenSearch domain"
  type        = list(string)
  default     = []
}

variable "opensearch_master_role_arn" {
  description = "IAM role ARN for the OpenSearch fine-grained access control master user"
  type        = string
}

variable "opensearch_ebs_volume_size" {
  description = "EBS volume size in GB per OpenSearch data node"
  type        = number
  default     = 1000
}

variable "opensearch_ebs_iops" {
  description = "EBS provisioned IOPS per OpenSearch data node (gp3)"
  type        = number
  default     = 3000
}

variable "opensearch_ebs_throughput" {
  description = "EBS throughput in MB/s per OpenSearch data node (gp3)"
  type        = number
  default     = 250
}

variable "opensearch_maintenance_start" {
  description = "ISO 8601 datetime for first auto-tune maintenance window"
  type        = string
  default     = "2024-01-01T02:00:00Z"
}

variable "opensearch_free_storage_threshold_mb" {
  description = "Free storage space alarm threshold in MB per data node"
  type        = number
  default     = 50000 # 50 GB
}

# ---------------------------------------------------------
# NEPTUNE VARIABLES (Requirement 10)
# ---------------------------------------------------------

variable "neptune_engine_version" {
  description = "Neptune engine version"
  type        = string
  default     = "1.3.1.0"
}

variable "neptune_instance_class" {
  description = "Neptune instance class for writer and reader instances"
  type        = string
  default     = "db.r6g.2xlarge"
}

variable "neptune_reader_count" {
  description = "Number of Neptune reader replicas"
  type        = number
  default     = 2
}

variable "neptune_max_reader_count" {
  description = "Maximum number of Neptune readers for auto-scaling"
  type        = number
  default     = 5
}

variable "neptune_parameter_group_family" {
  description = "Neptune parameter group family"
  type        = string
  default     = "neptune1.3"
}

variable "neptune_backup_window" {
  description = "Preferred backup window for Neptune cluster (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "neptune_maintenance_window" {
  description = "Preferred maintenance window for Neptune cluster (UTC)"
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "neptune_error_threshold" {
  description = "Threshold for Neptune Gremlin error alarm (number of errors per 5-min period)"
  type        = number
  default     = 50
}

variable "gold_layer_bucket_arn" {
  description = "ARN of the Gold Layer S3 bucket for Neptune bulk loader access"
  type        = string
}

# ---------------------------------------------------------
# ATHENA VARIABLES (Requirement 11)
# ---------------------------------------------------------

variable "glue_gold_database_name" {
  description = "Glue Data Catalog database name for Gold Layer tables"
  type        = string
  default     = "verticalbroker_gold"
}

# ---------------------------------------------------------
# MONITORING
# ---------------------------------------------------------

variable "alarm_sns_topic_arns" {
  description = "List of SNS topic ARNs for CloudWatch alarm notifications"
  type        = list(string)
  default     = []
}
