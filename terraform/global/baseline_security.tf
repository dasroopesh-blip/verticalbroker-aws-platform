# Account-Level Baseline Security Controls
# VerticalBroker AWS Data Engineering Platform
#
# Requirements: 20.5 (Baseline security: GuardDuty, Security Hub, Config, CloudTrail)
# Requirements: 14.5 (CloudTrail for compliance auditing)
# Requirements: 14.6 (Security event detection within 60 seconds)
# Requirements: 13.8 (Parameterized by account ID and OU for 100+ account scaling)
#
# This module deploys Organization-level delegated security services
# from the Management Account, automatically enrolling all member accounts.

# ---------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------

variable "security_account_id" {
  description = "Account ID of the delegated Security & Audit account"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_account_id))
    error_message = "Security account ID must be a 12-digit number."
  }
}

variable "enable_guardduty" {
  description = "Enable GuardDuty Organization-level deployment"
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Enable Security Hub Organization-level deployment"
  type        = bool
  default     = true
}


variable "enable_config" {
  description = "Enable AWS Config Organization-level deployment"
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Enable Organization CloudTrail"
  type        = bool
  default     = true
}

variable "cloudtrail_s3_bucket_name" {
  description = "S3 bucket for CloudTrail logs (in Security account)"
  type        = string
  default     = "verticalbroker-cloudtrail-logs"
}

variable "config_s3_bucket_name" {
  description = "S3 bucket for AWS Config delivery (in Security account)"
  type        = string
  default     = "verticalbroker-config-delivery"
}

variable "baseline_target_accounts" {
  description = "Map of account IDs to deploy baselines (supports 100+ accounts)"
  type        = map(object({
    account_id          = string
    organizational_unit = string
    environment         = string
  }))
  default = {}
}


# ---------------------------------------------------------
# GUARDDUTY - Organization-Level Delegation (Requirement 20.5)
# Threat detection across all member accounts
# ---------------------------------------------------------

resource "aws_guardduty_organization_admin_account" "security" {
  count = var.enable_guardduty ? 1 : 0

  admin_account_id = var.security_account_id
}

resource "aws_guardduty_detector" "management" {
  count = var.enable_guardduty ? 1 : 0

  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Environment        = "global"
    Service            = "guardduty"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


# Auto-enable GuardDuty for all new Organization members
resource "aws_guardduty_organization_configuration" "main" {
  count = var.enable_guardduty ? 1 : 0

  auto_enable_organization_members = "ALL"
  detector_id                      = aws_guardduty_detector.management[0].id

  datasources {
    s3_logs {
      auto_enable = true
    }
    kubernetes {
      audit_logs {
        auto_enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          auto_enable = true
        }
      }
    }
  }
}

# ---------------------------------------------------------
# SECURITY HUB - Organization-Level Delegation (Requirement 20.5)
# FSBP and CIS compliance standards across all accounts
# ---------------------------------------------------------

resource "aws_securityhub_organization_admin_account" "security" {
  count = var.enable_security_hub ? 1 : 0

  admin_account_id = var.security_account_id

  depends_on = [aws_guardduty_organization_admin_account.security]
}


resource "aws_securityhub_account" "management" {
  count = var.enable_security_hub ? 1 : 0

  enable_default_standards = false

  depends_on = [aws_securityhub_organization_admin_account.security]
}

# Enable AWS Foundational Security Best Practices standard
resource "aws_securityhub_standards_subscription" "fsbp" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.management]
}

# Enable CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.management]
}

# Auto-enable Security Hub for new member accounts
resource "aws_securityhub_organization_configuration" "main" {
  count = var.enable_security_hub ? 1 : 0

  auto_enable           = true
  auto_enable_standards = "DEFAULT"

  depends_on = [aws_securityhub_organization_admin_account.security]
}


# ---------------------------------------------------------
# CLOUDTRAIL - Organization Trail (Requirements 14.5, 20.5)
# Dedicated compliance trail stored in Security account
# ---------------------------------------------------------

resource "aws_cloudtrail" "organization" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "verticalbroker-organization-trail"
  s3_bucket_name                = var.cloudtrail_s3_bucket_name
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.cloudtrail[0].arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch[0].arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3"]
    }
  }

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  tags = {
    Environment        = "global"
    Service            = "cloudtrail"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


# CloudTrail KMS Key for log encryption
resource "aws_kms_key" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  description             = "KMS key for CloudTrail Organization trail encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:*:trail/*"
          }
        }
      },
      {
        Sid       = "AllowKeyManagement"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowSecurityAccountDecrypt"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.security_account_id}:root" }
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "cloudtrail-encryption"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_kms_alias" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name          = "alias/verticalbroker-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail[0].key_id
}


# CloudWatch Log Group for CloudTrail (management account)
resource "aws_cloudwatch_log_group" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name              = "/aws/cloudtrail/verticalbroker-organization"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.cloudtrail[0].arn

  tags = {
    Environment        = "global"
    Service            = "cloudtrail"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

# IAM Role for CloudTrail → CloudWatch Logs delivery
resource "aws_iam_role" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "verticalbroker-cloudtrail-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "cloudtrail"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "cloudtrail-cloudwatch-logs-policy"
  role = aws_iam_role.cloudtrail_cloudwatch[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
      }
    ]
  })
}

# ---------------------------------------------------------
# AWS CONFIG - Organization-Level (Requirement 20.5)
# Configuration recording and compliance rules
# ---------------------------------------------------------

resource "aws_config_configuration_aggregator" "organization" {
  count = var.enable_config ? 1 : 0

  name = "verticalbroker-organization-aggregator"

  organization_aggregation_source {
    all_regions = true
    role_arn    = aws_iam_role.config_aggregator[0].arn
  }

  tags = {
    Environment        = "global"
    Service            = "aws-config"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# IAM Role for Config Aggregator
resource "aws_iam_role" "config_aggregator" {
  count = var.enable_config ? 1 : 0

  name = "verticalbroker-config-aggregator-role"

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

  tags = {
    Environment        = "global"
    Service            = "aws-config"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config_aggregator[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}


# Organization-wide Config Rules for baseline compliance
resource "aws_config_organization_managed_rule" "s3_encryption" {
  count = var.enable_config ? 1 : 0

  name            = "s3-bucket-server-side-encryption-enabled"
  rule_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  description     = "Ensures all S3 buckets have server-side encryption enabled"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "s3_public_read" {
  count = var.enable_config ? 1 : 0

  name            = "s3-bucket-public-read-prohibited"
  rule_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  description     = "Ensures S3 buckets do not allow public read access"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "s3_public_write" {
  count = var.enable_config ? 1 : 0

  name            = "s3-bucket-public-write-prohibited"
  rule_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  description     = "Ensures S3 buckets do not allow public write access"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "encrypted_volumes" {
  count = var.enable_config ? 1 : 0

  name            = "encrypted-volumes"
  rule_identifier = "ENCRYPTED_VOLUMES"
  description     = "Ensures all EBS volumes are encrypted"

  depends_on = [aws_config_configuration_aggregator.organization]
}


resource "aws_config_organization_managed_rule" "rds_encryption" {
  count = var.enable_config ? 1 : 0

  name            = "rds-storage-encrypted"
  rule_identifier = "RDS_STORAGE_ENCRYPTED"
  description     = "Ensures all RDS instances have encryption at rest enabled"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "root_mfa" {
  count = var.enable_config ? 1 : 0

  name            = "root-account-mfa-enabled"
  rule_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  description     = "Ensures root account has MFA enabled in all accounts"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "iam_root_access_key" {
  count = var.enable_config ? 1 : 0

  name            = "iam-root-access-key-check"
  rule_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  description     = "Ensures root account does not have access keys"

  depends_on = [aws_config_configuration_aggregator.organization]
}

resource "aws_config_organization_managed_rule" "cloudtrail_enabled" {
  count = var.enable_config ? 1 : 0

  name            = "cloud-trail-enabled"
  rule_identifier = "CLOUD_TRAIL_ENABLED"
  description     = "Ensures CloudTrail is enabled in all accounts"

  depends_on = [aws_config_configuration_aggregator.organization]
}


resource "aws_config_organization_managed_rule" "required_tags" {
  count = var.enable_config ? 1 : 0

  name            = "required-tags"
  rule_identifier = "REQUIRED_TAGS"
  description     = "Ensures all resources have mandatory tags (Requirement 13.5)"

  input_parameters = jsonencode({
    tag1Key = "Environment"
    tag2Key = "Service"
    tag3Key = "Owner"
    tag4Key = "CostCenter"
    tag5Key = "DataClassification"
    tag6Key = "Compliance"
  })

  depends_on = [aws_config_configuration_aggregator.organization]
}

# ---------------------------------------------------------
# IAM ACCESS ANALYZER - Organization-Level
# Identifies unintended resource access across accounts
# ---------------------------------------------------------

resource "aws_accessanalyzer_analyzer" "organization" {
  analyzer_name = "verticalbroker-organization-analyzer"
  type          = "ORGANIZATION"

  tags = {
    Environment        = "global"
    Service            = "access-analyzer"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# ---------------------------------------------------------
# ACCOUNT BASELINE MODULE
# Reusable module for deploying security baselines per account
# Parameterized by account_id and organizational_unit (Req 13.8)
# ---------------------------------------------------------

# This module can be called for each account to deploy baselines
module "account_baseline" {
  source   = "../modules/security/account-baseline"
  for_each = var.baseline_target_accounts

  providers = {
    aws = aws
  }

  account_id          = each.value.account_id
  organizational_unit = each.value.organizational_unit
  environment         = each.value.environment

  # Security services configuration
  enable_guardduty    = var.enable_guardduty
  enable_security_hub = var.enable_security_hub
  enable_config       = var.enable_config

  # Centralized logging
  cloudtrail_s3_bucket = var.cloudtrail_s3_bucket_name
  config_s3_bucket     = var.config_s3_bucket_name
  security_account_id  = var.security_account_id

  # Mandatory tags
  tags = {
    Environment        = each.value.environment
    Service            = "security-baseline"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# ---------------------------------------------------------
# SECURITY EVENT NOTIFICATIONS (Requirement 14.6)
# Alert within 60 seconds of security event detection
# ---------------------------------------------------------

resource "aws_sns_topic" "security_alerts" {
  name              = "verticalbroker-security-alerts"
  kms_master_key_id = var.enable_cloudtrail ? aws_kms_key.cloudtrail[0].id : null

  tags = {
    Environment        = "global"
    Service            = "security-alerts"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      },
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}


# EventBridge rule for GuardDuty HIGH/CRITICAL findings → SNS
resource "aws_cloudwatch_event_rule" "guardduty_high_findings" {
  count = var.enable_guardduty ? 1 : 0

  name        = "guardduty-high-severity-findings"
  description = "Routes GuardDuty HIGH/CRITICAL findings to security team (Req 14.6: <60s)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })

  tags = {
    Environment        = "global"
    Service            = "security-alerts"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  count = var.enable_guardduty ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_high_findings[0].name
  target_id = "send-to-security-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# EventBridge rule for Security Hub CRITICAL findings → SNS
resource "aws_cloudwatch_event_rule" "securityhub_critical" {
  count = var.enable_security_hub ? 1 : 0

  name        = "securityhub-critical-findings"
  description = "Routes Security Hub CRITICAL findings to security team"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = {
          Label = ["CRITICAL", "HIGH"]
        }
      }
    }
  })

  tags = {
    Environment        = "global"
    Service            = "security-alerts"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_cloudwatch_event_target" "securityhub_to_sns" {
  count = var.enable_security_hub ? 1 : 0

  rule      = aws_cloudwatch_event_rule.securityhub_critical[0].name
  target_id = "send-to-security-sns"
  arn       = aws_sns_topic.security_alerts.arn
}


# ---------------------------------------------------------
# DATA SOURCE
# ---------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "guardduty_detector_id" {
  description = "GuardDuty detector ID in management account"
  value       = var.enable_guardduty ? aws_guardduty_detector.management[0].id : null
}

output "cloudtrail_arn" {
  description = "Organization CloudTrail ARN"
  value       = var.enable_cloudtrail ? aws_cloudtrail.organization[0].arn : null
}

output "cloudtrail_kms_key_arn" {
  description = "KMS key ARN used for CloudTrail encryption"
  value       = var.enable_cloudtrail ? aws_kms_key.cloudtrail[0].arn : null
}

output "security_alerts_topic_arn" {
  description = "SNS topic ARN for security alerts"
  value       = aws_sns_topic.security_alerts.arn
}

output "config_aggregator_name" {
  description = "AWS Config aggregator name"
  value       = var.enable_config ? aws_config_configuration_aggregator.organization[0].name : null
}

output "access_analyzer_arn" {
  description = "IAM Access Analyzer ARN"
  value       = aws_accessanalyzer_analyzer.organization.arn
}
