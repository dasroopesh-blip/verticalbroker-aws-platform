# Streaming Module Variables
# VerticalBroker AWS Data Engineering Platform
#
# Input variables for the streaming module components:
#   - EventBridge (event bus, schema registry, routing rules, archive)
#   - Kinesis Data Streams (market data ingestion)
#   - SQS Queues (trade processing, buffering, DLQs)
#
# Requirements: 6.1-6.6, 1.3, 1.4, 13.5

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
# KINESIS CONFIGURATION
# Requirement 1.3: Market data ingestion streaming
# ---------------------------------------------------------

variable "market_data_stream_name" {
  description = "Override name for the Kinesis market data stream (default: vb-market-data-{env})"
  type        = string
  default     = ""
}

variable "kinesis_shard_count" {
  description = "Number of provisioned shards for market data stream (16 = 12 burst + 33% headroom)"
  type        = number
  default     = 16

  validation {
    condition     = var.kinesis_shard_count >= 1
    error_message = "Kinesis shard count must be at least 1."
  }
}

variable "kinesis_retention_hours" {
  description = "Kinesis data retention in hours (168 = 7 days for replay capability)"
  type        = number
  default     = 168

  validation {
    condition     = var.kinesis_retention_hours >= 24 && var.kinesis_retention_hours <= 8760
    error_message = "Kinesis retention must be between 24 hours and 8760 hours (365 days)."
  }
}

variable "kinesis_stream_mode" {
  description = "Kinesis stream capacity mode (ON_DEMAND for auto-scaling beyond provisioned shards)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "PROVISIONED"], var.kinesis_stream_mode)
    error_message = "Kinesis stream mode must be ON_DEMAND or PROVISIONED."
  }
}

variable "kinesis_encryption_type" {
  description = "Encryption type for Kinesis stream (KMS for customer-managed key)"
  type        = string
  default     = "KMS"

  validation {
    condition     = contains(["NONE", "KMS"], var.kinesis_encryption_type)
    error_message = "Kinesis encryption type must be NONE or KMS."
  }
}

variable "kinesis_enable_enhanced_monitoring" {
  description = "Enable shard-level enhanced monitoring metrics"
  type        = bool
  default     = true
}

variable "kinesis_shard_level_metrics" {
  description = "List of shard-level metrics to enable when enhanced monitoring is active"
  type        = list(string)
  default = [
    "IncomingBytes",
    "IncomingRecords",
    "OutgoingBytes",
    "OutgoingRecords",
    "WriteProvisionedThroughputExceeded",
    "ReadProvisionedThroughputExceeded",
    "IteratorAgeMilliseconds"
  ]
}


# ---------------------------------------------------------
# SQS CONFIGURATION
# Requirements: 6.4, 6.5, 1.4
# ---------------------------------------------------------

variable "kms_key_arn" {
  description = "KMS CMK ARN for encrypting Kinesis streams and SQS queues (Confidential classification)"
  type        = string
}

variable "eventbridge_bus_name" {
  description = "EventBridge bus name for SQS queue policy conditions (set automatically from event bus)"
  type        = string
  default     = ""
}

variable "queue_depth_alarm_threshold" {
  description = "Threshold for SQS queue depth CloudWatch alarm (Requirement 15.2: 10,000 messages)"
  type        = number
  default     = 10000

  validation {
    condition     = var.queue_depth_alarm_threshold >= 1
    error_message = "Queue depth alarm threshold must be at least 1."
  }
}

variable "monitoring_sns_topic_arn" {
  description = "SNS topic ARN for SQS queue depth and DLQ monitoring alarms"
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# EVENTBRIDGE CONFIGURATION
# Requirements: 6.1, 6.2, 6.3, 6.6
# ---------------------------------------------------------

variable "step_functions_arn" {
  description = "ARN of the Step Functions ETL orchestrator state machine (target for data.ingested events)"
  type        = string
}

variable "trade_processing_queue_arn" {
  description = "ARN of the SQS FIFO queue for trade processing (target for trade.executed events)"
  type        = string
}

variable "operations_sns_topic_arn" {
  description = "ARN of the SNS topic for operations team notifications (pipeline failures, alarms)"
  type        = string
}

variable "security_sns_topic_arn" {
  description = "ARN of the SNS topic for security team notifications (compliance alerts)"
  type        = string
}

variable "event_archive_retention_days" {
  description = "Retention period in days for the unmatched events archive (Requirement 6.6)"
  type        = number
  default     = 30

  validation {
    condition     = var.event_archive_retention_days >= 1 && var.event_archive_retention_days <= 365
    error_message = "Event archive retention must be between 1 and 365 days."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for event-related log groups"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2556, 3653], var.log_retention_days)
    error_message = "Log retention must be a valid CloudWatch retention period."
  }
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



# ---------------------------------------------------------
# DMS CDC CONFIGURATION
# Requirements: 5.1, 5.2, 5.3, 5.4, 5.6
# ---------------------------------------------------------

variable "dms_instance_class" {
  description = "DMS replication instance class (dms.r6i.2xlarge for CDC throughput)"
  type        = string
  default     = "dms.r6i.2xlarge"
}

variable "dms_allocated_storage_gb" {
  description = "Allocated storage for DMS replication instance in GB"
  type        = number
  default     = 256

  validation {
    condition     = var.dms_allocated_storage_gb >= 50 && var.dms_allocated_storage_gb <= 6144
    error_message = "DMS allocated storage must be between 50 and 6144 GB."
  }
}

variable "dms_engine_version" {
  description = "DMS replication engine version"
  type        = string
  default     = "3.5.2"
}

variable "dms_multi_az" {
  description = "Enable Multi-AZ deployment for DMS replication instance (recommended for production)"
  type        = bool
  default     = true
}

variable "dms_subnet_ids" {
  description = "List of subnet IDs for the DMS replication subnet group (private data subnets)"
  type        = list(string)
}

variable "dms_security_group_ids" {
  description = "List of security group IDs for the DMS replication instance"
  type        = list(string)
}

variable "dms_maintenance_window" {
  description = "Preferred maintenance window for DMS instance (UTC)"
  type        = string
  default     = "sun:03:00-sun:04:00"
}

variable "dms_replication_lag_threshold_seconds" {
  description = "Threshold in seconds for DMS replication lag alarm (Requirement 5.4: 60 seconds)"
  type        = number
  default     = 60

  validation {
    condition     = var.dms_replication_lag_threshold_seconds >= 1
    error_message = "Replication lag threshold must be at least 1 second."
  }
}

variable "dms_parallel_load_threads" {
  description = "Number of parallel load threads for full-load phase"
  type        = number
  default     = 8

  validation {
    condition     = var.dms_parallel_load_threads >= 1 && var.dms_parallel_load_threads <= 32
    error_message = "Parallel load threads must be between 1 and 32."
  }
}

variable "dms_parallel_load_buffer_size" {
  description = "Buffer size for parallel load threads (in number of records)"
  type        = number
  default     = 1000
}

variable "dms_max_full_load_subtasks" {
  description = "Maximum number of tables to load in parallel during full load"
  type        = number
  default     = 8

  validation {
    condition     = var.dms_max_full_load_subtasks >= 1 && var.dms_max_full_load_subtasks <= 49
    error_message = "Max full load subtasks must be between 1 and 49."
  }
}

# ---------------------------------------------------------
# DMS SOURCE DATABASE CONFIGURATION
# ---------------------------------------------------------

variable "source_db_hostname" {
  description = "Hostname of the source RDS/Aurora PostgreSQL instance"
  type        = string
}

variable "source_db_port" {
  description = "Port of the source database"
  type        = number
  default     = 5432
}

variable "source_db_name" {
  description = "Name of the source database"
  type        = string
  default     = "verticalbroker"
}

variable "source_db_username" {
  description = "Username for the source database DMS connection"
  type        = string
  sensitive   = true
}

variable "source_db_password" {
  description = "Password for the source database DMS connection"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------
# DMS TARGET S3 CONFIGURATION
# ---------------------------------------------------------

variable "bronze_bucket_name" {
  description = "Name of the S3 Bronze layer bucket for CDC target"
  type        = string
}

variable "dms_s3_target_role_arn" {
  description = "IAM role ARN for DMS to write to S3 target endpoint"
  type        = string
}
