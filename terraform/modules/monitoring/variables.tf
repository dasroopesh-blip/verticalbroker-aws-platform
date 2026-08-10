# Monitoring Module Variables
# VerticalBroker AWS Data Engineering Platform
#
# Input variables for the monitoring and observability module.
# Covers CloudWatch dashboards/alarms, SNS alerting, X-Ray tracing,
# SSM Automation runbooks, and AWS Budgets cost management.
#
# Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.7, 17.1, 17.3

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
  description = "Resource naming prefix: {platform}-{environment}"
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID for ARN construction"
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
      contains(keys(var.mandatory_tags), "DataClassification"),
      contains(keys(var.mandatory_tags), "Compliance"),
    ])
    error_message = "mandatory_tags must include: Environment, Service, Owner, CostCenter, DataClassification, Compliance."
  }
}

# ---------------------------------------------------------
# CLOUDWATCH VARIABLES
# ---------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Log Group retention in days (Requirement 15.6: 90 days operational)"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch retention period."
  }
}

variable "alarm_evaluation_periods" {
  description = "Number of evaluation periods before triggering alarm (avoids flapping)"
  type        = number
  default     = 3
}

variable "alarm_datapoints_to_alarm" {
  description = "Number of datapoints within evaluation periods that must breach threshold"
  type        = number
  default     = 2
}

variable "pipeline_latency_sla_seconds" {
  description = "SLA threshold for pipeline latency alarm (seconds)"
  type        = number
  default     = 300
}

variable "api_error_rate_threshold_pct" {
  description = "API error rate threshold percentage to trigger alarm"
  type        = number
  default     = 1.0
}

variable "sqs_depth_threshold" {
  description = "SQS queue depth threshold to trigger alarm"
  type        = number
  default     = 10000
}

variable "cpu_utilization_threshold_pct" {
  description = "Infrastructure CPU utilization threshold percentage"
  type        = number
  default     = 80
}

variable "cdc_replication_lag_threshold_seconds" {
  description = "CDC replication lag threshold in seconds"
  type        = number
  default     = 60
}

variable "kinesis_iterator_age_threshold_ms" {
  description = "Kinesis iterator age threshold in milliseconds"
  type        = number
  default     = 5000
}

# ---------------------------------------------------------
# SNS VARIABLES
# ---------------------------------------------------------

variable "operations_email_endpoints" {
  description = "Email addresses for operations team notifications"
  type        = list(string)
  default     = []
}

variable "pagerduty_endpoint_url" {
  description = "PagerDuty HTTPS integration endpoint URL for operations alerts"
  type        = string
  default     = ""
  sensitive   = true
}

variable "security_email_endpoints" {
  description = "Email addresses for security/compliance team notifications"
  type        = list(string)
  default     = []
}

variable "finance_email_endpoints" {
  description = "Email addresses for finance team cost notifications"
  type        = list(string)
  default     = []
}

variable "sns_kms_key_arn" {
  description = "KMS key ARN for encrypting SNS topics. If empty, a new key is created."
  type        = string
  default     = ""
}

# ---------------------------------------------------------
# X-RAY VARIABLES
# ---------------------------------------------------------

variable "xray_normal_sampling_rate" {
  description = "X-Ray sampling rate for normal traffic (0.0 to 1.0)"
  type        = number
  default     = 0.05

  validation {
    condition     = var.xray_normal_sampling_rate >= 0 && var.xray_normal_sampling_rate <= 1
    error_message = "xray_normal_sampling_rate must be between 0.0 and 1.0."
  }
}

variable "xray_error_sampling_rate" {
  description = "X-Ray sampling rate for error paths (0.0 to 1.0)"
  type        = number
  default     = 1.0

  validation {
    condition     = var.xray_error_sampling_rate >= 0 && var.xray_error_sampling_rate <= 1
    error_message = "xray_error_sampling_rate must be between 0.0 and 1.0."
  }
}

variable "xray_service_names" {
  description = "List of service names for X-Ray group definitions"
  type        = list(string)
  default = [
    "market-data-ingestion",
    "order-manager",
    "wallet-service",
    "advisory-agent",
    "etl-pipeline",
  ]
}

# ---------------------------------------------------------
# SSM AUTOMATION VARIABLES
# ---------------------------------------------------------

variable "ssm_automation_role_arn" {
  description = "IAM role ARN for SSM Automation document execution"
  type        = string
  default     = ""
}

variable "ssm_max_execution_timeout_seconds" {
  description = "Maximum execution timeout for SSM Automation runbooks (seconds)"
  type        = number
  default     = 300
}

variable "ssm_max_retries_per_incident" {
  description = "Maximum retry attempts per incident for SSM Automation"
  type        = number
  default     = 3
}

# ---------------------------------------------------------
# BUDGETS VARIABLES
# ---------------------------------------------------------

variable "budget_limit_amount" {
  description = "Monthly budget limit amount in USD"
  type        = string
  default     = "50000"
}

variable "budget_threshold_pct" {
  description = "Budget threshold percentage for alerting (e.g., 80 for 80%)"
  type        = number
  default     = 80
}

variable "cost_center_budgets" {
  description = "Map of CostCenter tag values to their monthly budget limit in USD"
  type        = map(string)
  default = {
    "data-platform"  = "25000"
    "trading"        = "15000"
    "analytics"      = "10000"
    "ml-advisory"    = "8000"
    "infrastructure" = "5000"
  }
}

# ---------------------------------------------------------
# RESOURCE REFERENCE VARIABLES
# (Used for alarm metric dimensions and composite alarm references)
# ---------------------------------------------------------

variable "kinesis_stream_name" {
  description = "Name of the Kinesis Data Stream for market data ingestion"
  type        = string
  default     = ""
}

variable "sqs_queue_names" {
  description = "List of SQS queue names to monitor"
  type        = list(string)
  default     = []
}

variable "lambda_function_names" {
  description = "List of Lambda function names to monitor"
  type        = list(string)
  default     = []
}

variable "glue_job_names" {
  description = "List of Glue job names to monitor"
  type        = list(string)
  default     = []
}

variable "api_gateway_id" {
  description = "API Gateway ID for performance monitoring"
  type        = string
  default     = ""
}

variable "dms_replication_instance_id" {
  description = "DMS replication instance identifier for CDC lag monitoring"
  type        = string
  default     = ""
}
