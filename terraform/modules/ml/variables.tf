# ML Module Variables - VerticalBroker AWS Data Engineering Platform
#
# Input variables for SageMaker training, inference, model registry,
# and monitoring infrastructure.
#
# Requirements: 12.2, 12.3, 12.4, 12.7, 12.8, 13.5

# =============================================================================
# COMMON VARIABLES
# =============================================================================

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
  description = "AWS region for resource deployment"
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

# =============================================================================
# VPC CONFIGURATION
# =============================================================================

variable "vpc_id" {
  description = "VPC ID for SageMaker Domain network configuration"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for SageMaker Domain and endpoints"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for SageMaker resources"
  type        = list(string)
  default     = []
}

# =============================================================================
# IAM CONFIGURATION
# =============================================================================

variable "sagemaker_execution_role_arn" {
  description = "IAM role ARN for SageMaker execution (training, inference, pipeline)"
  type        = string
}

variable "model_monitor_role_arn" {
  description = "IAM role ARN for SageMaker Model Monitor jobs"
  type        = string
  default     = ""
}

# =============================================================================
# SAGEMAKER DOMAIN
# =============================================================================

variable "sagemaker_domain_name" {
  description = "Name of the SageMaker Domain"
  type        = string
  default     = "verticalbroker-ml-domain"
}

variable "sagemaker_auth_mode" {
  description = "Authentication mode for SageMaker Domain (IAM or SSO)"
  type        = string
  default     = "IAM"

  validation {
    condition     = contains(["IAM", "SSO"], var.sagemaker_auth_mode)
    error_message = "Auth mode must be IAM or SSO."
  }
}

# =============================================================================
# MODEL REGISTRY
# =============================================================================

variable "model_package_group_name" {
  description = "SageMaker Model Package Group name for advisory models"
  type        = string
  default     = "verticalbroker-advisory-models"
}

variable "model_package_group_description" {
  description = "Description of the model package group"
  type        = string
  default     = "RL-based advisory models for automated investment recommendations"
}

# =============================================================================
# ENDPOINT CONFIGURATION
# =============================================================================

variable "endpoint_name" {
  description = "SageMaker real-time inference endpoint name"
  type        = string
  default     = "vb-advisory-endpoint"
}

variable "production_variant_instance_type" {
  description = "Instance type for the production endpoint variant"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "production_variant_instance_count" {
  description = "Initial instance count for the production variant"
  type        = number
  default     = 2
}

variable "production_variant_weight" {
  description = "Traffic weight for the production variant (0-100)"
  type        = number
  default     = 90
}

variable "canary_variant_instance_type" {
  description = "Instance type for the canary endpoint variant"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "canary_variant_instance_count" {
  description = "Initial instance count for the canary variant"
  type        = number
  default     = 1
}

variable "canary_variant_weight" {
  description = "Traffic weight for the canary variant (0-100)"
  type        = number
  default     = 10
}

# =============================================================================
# AUTO-SCALING CONFIGURATION
# =============================================================================

variable "autoscaling_min_capacity" {
  description = "Minimum number of inference instances"
  type        = number
  default     = 1
}

variable "autoscaling_max_capacity" {
  description = "Maximum number of inference instances"
  type        = number
  default     = 10
}

variable "autoscaling_target_invocations" {
  description = "Target invocations per instance for auto-scaling"
  type        = number
  default     = 750
}

variable "autoscaling_scale_in_cooldown" {
  description = "Scale-in cooldown period in seconds"
  type        = number
  default     = 300
}

variable "autoscaling_scale_out_cooldown" {
  description = "Scale-out cooldown period in seconds"
  type        = number
  default     = 60
}

# =============================================================================
# MODEL MONITOR CONFIGURATION
# =============================================================================

variable "enable_model_monitor" {
  description = "Enable SageMaker Model Monitor for data and model quality"
  type        = bool
  default     = true
}

variable "monitor_schedule_expression" {
  description = "Cron expression for Model Monitor schedule"
  type        = string
  default     = "cron(0 * ? * * *)"
}

variable "monitor_instance_type" {
  description = "Instance type for Model Monitor processing jobs"
  type        = string
  default     = "ml.m5.large"
}

variable "monitor_output_s3_uri" {
  description = "S3 URI for Model Monitor output artifacts"
  type        = string
  default     = ""
}

# =============================================================================
# TRAINING PIPELINE CONFIGURATION
# =============================================================================

variable "pipeline_name" {
  description = "SageMaker Pipeline name for advisory model training"
  type        = string
  default     = "verticalbroker-advisory-training"
}

variable "feature_engineering_instance_type" {
  description = "Instance type for feature engineering processing jobs"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "feature_engineering_instance_count" {
  description = "Instance count for feature engineering processing jobs"
  type        = number
  default     = 1
}

variable "training_instance_type" {
  description = "Instance type for RL training jobs (GPU required)"
  type        = string
  default     = "ml.p3.2xlarge"
}

variable "training_instance_count" {
  description = "Instance count for training jobs"
  type        = number
  default     = 1
}

variable "training_max_runtime_seconds" {
  description = "Maximum runtime for training jobs in seconds"
  type        = number
  default     = 86400
}

variable "evaluation_instance_type" {
  description = "Instance type for model evaluation processing jobs"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "gold_layer_bucket_name" {
  description = "S3 bucket name for Gold layer training data"
  type        = string
}

variable "model_artifacts_bucket_name" {
  description = "S3 bucket name for model artifacts storage"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting SageMaker resources"
  type        = string
}
