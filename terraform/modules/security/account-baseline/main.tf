# Account Baseline Security Module
# Deploys security baselines to individual member accounts
# Parameterized by account_id and organizational_unit (Requirement 13.8)
# Supports 100+ account scaling via for_each in calling module
#
# Requirements: 20.5, 14.5, 14.6

# ---------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------

variable "account_id" {
  description = "Target AWS account ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Account ID must be a 12-digit number."
  }
}

variable "organizational_unit" {
  description = "OU this account belongs to"
  type        = string
}

variable "environment" {
  description = "Environment for this account (dev, staging, production, dr)"
  type        = string
}

variable "enable_guardduty" {
  description = "Enable GuardDuty in target account"
  type        = bool
  default     = true
}


variable "enable_security_hub" {
  description = "Enable Security Hub in target account"
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Enable AWS Config in target account"
  type        = bool
  default     = true
}

variable "cloudtrail_s3_bucket" {
  description = "Centralized S3 bucket for CloudTrail logs"
  type        = string
}

variable "config_s3_bucket" {
  description = "Centralized S3 bucket for Config delivery"
  type        = string
}

variable "security_account_id" {
  description = "Security & Audit delegated admin account ID"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}


# ---------------------------------------------------------
# AWS CONFIG - Per-Account Configuration Recorder
# ---------------------------------------------------------

resource "aws_config_configuration_recorder" "account" {
  count = var.enable_config ? 1 : 0

  name     = "verticalbroker-config-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "account" {
  count = var.enable_config ? 1 : 0

  name           = "verticalbroker-config-delivery"
  s3_bucket_name = var.config_s3_bucket

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.account]
}

resource "aws_config_configuration_recorder_status" "account" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.account[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.account]
}


# IAM Role for AWS Config
resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name = "verticalbroker-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0

  name = "config-s3-delivery"
  role = aws_iam_role.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [
          "arn:aws:s3:::${var.config_s3_bucket}",
          "arn:aws:s3:::${var.config_s3_bucket}/AWSLogs/${var.account_id}/*"
        ]
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}


# ---------------------------------------------------------
# S3 PUBLIC ACCESS BLOCK - Account Level
# Ensures no public buckets can be created
# ---------------------------------------------------------

resource "aws_s3_account_public_access_block" "account" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------
# EBS DEFAULT ENCRYPTION - Account Level
# Enforces encryption for all new EBS volumes
# ---------------------------------------------------------

resource "aws_ebs_encryption_by_default" "account" {
  enabled = true
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "account_id" {
  description = "Account ID this baseline was deployed to"
  value       = var.account_id
}

output "organizational_unit" {
  description = "OU this account belongs to"
  value       = var.organizational_unit
}

output "config_recorder_id" {
  description = "Config recorder ID"
  value       = var.enable_config ? aws_config_configuration_recorder.account[0].id : null
}
