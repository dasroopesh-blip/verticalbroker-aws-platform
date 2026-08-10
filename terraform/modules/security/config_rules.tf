# AWS Config Conformance Packs and Rules
# VerticalBroker AWS Data Engineering Platform
#
# Purpose: Per-environment AWS Config conformance packs with rules for:
#          - S3 encryption enforcement
#          - Public access prevention
#          - Required tag compliance
#          - IAM policy compliance
#          - KMS key rotation
#          - VPC flow logs enablement
#          Complements Organization-level Config rules in global/baseline_security.tf.
#
# Requirements: 14.5 (Compliance auditing)
# Requirements: 14.6 (Security event detection)
# Requirements: 14.8 (SOC 2 Type II evidence generation)
# Requirements: 20.5 (Baseline security controls)

# ---------------------------------------------------------
# CONFORMANCE PACK - Encryption Compliance (Requirement 14.5, 14.8)
# Validates all data at rest is encrypted with KMS CMKs
# ---------------------------------------------------------

resource "aws_config_conformance_pack" "encryption" {
  count = var.enable_config_rules ? 1 : 0

  name = "${var.platform_name}-${var.environment}-encryption-compliance"

  template_body = <<-TEMPLATE
    Resources:
      S3BucketServerSideEncryptionEnabled:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-encryption-enabled
          Description: "Ensures all S3 buckets have server-side encryption with KMS (Req 14.1)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
      S3DefaultEncryptionKMS:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-default-encryption-kms
          Description: "Ensures S3 buckets use KMS for default encryption (Req 14.1)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_DEFAULT_ENCRYPTION_KMS
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
      EncryptedVolumes:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-encrypted-volumes
          Description: "Ensures all EBS volumes are encrypted (Req 14.1)"
          Source:
            Owner: AWS
            SourceIdentifier: ENCRYPTED_VOLUMES
          Scope:
            ComplianceResourceTypes:
              - AWS::EC2::Volume
      RDSStorageEncrypted:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-rds-storage-encrypted
          Description: "Ensures RDS instances have encryption at rest (Req 14.1)"
          Source:
            Owner: AWS
            SourceIdentifier: RDS_STORAGE_ENCRYPTED
          Scope:
            ComplianceResourceTypes:
              - AWS::RDS::DBInstance
      DynamoDBEncryption:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-dynamodb-table-encrypted-kms
          Description: "Ensures DynamoDB tables are encrypted with KMS (Req 14.1)"
          Source:
            Owner: AWS
            SourceIdentifier: DYNAMODB_TABLE_ENCRYPTED_KMS
          Scope:
            ComplianceResourceTypes:
              - AWS::DynamoDB::Table
  TEMPLATE

  depends_on = [aws_config_configuration_recorder_status.environment]

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-encryption-conformance-pack"
    Service = "aws-config"
  })
}

# ---------------------------------------------------------
# CONFORMANCE PACK - Public Access Prevention (Requirement 14.5, 20.5)
# Ensures no resources are publicly exposed
# ---------------------------------------------------------

resource "aws_config_conformance_pack" "public_access" {
  count = var.enable_config_rules ? 1 : 0

  name = "${var.platform_name}-${var.environment}-public-access-prevention"

  template_body = <<-TEMPLATE
    Resources:
      S3BucketPublicReadProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-public-read-prohibited
          Description: "Ensures S3 buckets do not allow public read access (Req 20.5)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
      S3BucketPublicWriteProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-public-write-prohibited
          Description: "Ensures S3 buckets do not allow public write access (Req 20.5)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_PUBLIC_WRITE_PROHIBITED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
      S3AccountLevelPublicAccessBlocks:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-account-public-access
          Description: "Ensures account-level S3 public access block is enabled (Req 20.5)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_ACCOUNT_LEVEL_PUBLIC_ACCESS_BLOCKS
      S3BucketLevelPublicAccessProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-s3-bucket-level-public-access
          Description: "Ensures bucket-level public access block is enabled (Req 20.5)"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
      LambdaFunctionPublicAccessProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-lambda-public-access-prohibited
          Description: "Ensures Lambda functions are not publicly accessible"
          Source:
            Owner: AWS
            SourceIdentifier: LAMBDA_FUNCTION_PUBLIC_ACCESS_PROHIBITED
          Scope:
            ComplianceResourceTypes:
              - AWS::Lambda::Function
      RDSInstancePublicAccessCheck:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-rds-instance-public-access
          Description: "Ensures RDS instances are not publicly accessible"
          Source:
            Owner: AWS
            SourceIdentifier: RDS_INSTANCE_PUBLIC_ACCESS_CHECK
          Scope:
            ComplianceResourceTypes:
              - AWS::RDS::DBInstance
  TEMPLATE

  depends_on = [aws_config_configuration_recorder_status.environment]

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-public-access-conformance-pack"
    Service = "aws-config"
  })
}

# ---------------------------------------------------------
# CONFORMANCE PACK - Tagging Compliance (Requirement 13.5, 14.8)
# Ensures all resources have mandatory tags for cost allocation,
# compliance tracking, and SOC 2 evidence
# ---------------------------------------------------------

resource "aws_config_conformance_pack" "tagging" {
  count = var.enable_config_rules ? 1 : 0

  name = "${var.platform_name}-${var.environment}-tagging-compliance"

  template_body = <<-TEMPLATE
    Resources:
      RequiredTags:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: ${var.platform_name}-${var.environment}-required-tags
          Description: "Ensures resources have mandatory tags: Environment, Service, Owner, CostCenter, DataClassification, Compliance (Req 13.5)"
          Source:
            Owner: AWS
            SourceIdentifier: REQUIRED_TAGS
          InputParameters:
            tag1Key: "Environment"
            tag2Key: "Service"
            tag3Key: "Owner"
            tag4Key: "CostCenter"
            tag5Key: "DataClassification"
            tag6Key: "Compliance"
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket
              - AWS::Lambda::Function
              - AWS::DynamoDB::Table
              - AWS::KMS::Key
              - AWS::SQS::Queue
              - AWS::SNS::Topic
  TEMPLATE

  depends_on = [aws_config_configuration_recorder_status.environment]

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-tagging-conformance-pack"
    Service = "aws-config"
  })
}

# ---------------------------------------------------------
# INDIVIDUAL CONFIG RULES - IAM Policy Compliance (Requirement 14.5)
# ---------------------------------------------------------

resource "aws_config_config_rule" "iam_no_inline_policy" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-iam-no-inline-policy-check"
  description = "Ensures IAM users do not have inline policies (least-privilege enforcement)"

  source {
    owner             = "AWS"
    source_identifier = "IAM_NO_INLINE_POLICY_CHECK"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::User"]
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-iam-no-inline-policy"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

resource "aws_config_config_rule" "iam_policy_no_admin" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-iam-policy-no-statements-with-admin-access"
  description = "Ensures no IAM policies grant full admin access (Req 13.4)"

  source {
    owner             = "AWS"
    source_identifier = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::Policy"]
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-iam-no-admin-policy"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

resource "aws_config_config_rule" "iam_policy_no_wildcard" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-iam-policy-no-statements-with-full-access"
  description = "Ensures no IAM policies use wildcard (*) for actions (Req 13.4)"

  source {
    owner             = "AWS"
    source_identifier = "IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::Policy"]
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-iam-no-wildcard-policy"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

# ---------------------------------------------------------
# INDIVIDUAL CONFIG RULES - KMS Key Rotation (Requirement 2.5)
# ---------------------------------------------------------

resource "aws_config_config_rule" "kms_key_rotation" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-cmk-backing-key-rotation-enabled"
  description = "Ensures KMS CMKs have automatic annual key rotation enabled (Req 2.5)"

  source {
    owner             = "AWS"
    source_identifier = "CMK_BACKING_KEY_ROTATION_ENABLED"
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-kms-rotation-check"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

# ---------------------------------------------------------
# INDIVIDUAL CONFIG RULES - VPC Flow Logs (Requirement 20.6)
# ---------------------------------------------------------

resource "aws_config_config_rule" "vpc_flow_logs_enabled" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-vpc-flow-logs-enabled"
  description = "Ensures VPC flow logs are enabled for network audit trail (Req 20.6)"

  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-vpc-flow-logs-check"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

# ---------------------------------------------------------
# INDIVIDUAL CONFIG RULES - CloudTrail Enabled (Requirement 14.5)
# ---------------------------------------------------------

resource "aws_config_config_rule" "cloudtrail_enabled" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-cloud-trail-enabled"
  description = "Ensures CloudTrail is enabled in this account (Req 14.5)"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-cloudtrail-enabled-check"
    Service = "aws-config"
  })

  depends_on = [aws_config_configuration_recorder_status.environment]
}

# ---------------------------------------------------------
# AWS CONFIG RECORDER - Per-Environment (Requirement 20.5)
# Required for conformance packs and individual rules
# ---------------------------------------------------------

resource "aws_config_configuration_recorder" "environment" {
  count = var.enable_config_rules ? 1 : 0

  name     = "${var.platform_name}-${var.environment}-config-recorder"
  role_arn = aws_iam_role.config_recorder[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.environment == "production"
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }
}

resource "aws_config_delivery_channel" "environment" {
  count = var.enable_config_rules ? 1 : 0

  name           = "${var.platform_name}-${var.environment}-config-delivery"
  s3_bucket_name = var.cloudtrail_s3_bucket_name != "" ? var.cloudtrail_s3_bucket_name : "${var.platform_name}-${var.environment}-config-delivery"
  s3_key_prefix  = "${var.environment}/config"

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.environment]
}

resource "aws_config_configuration_recorder_status" "environment" {
  count = var.enable_config_rules ? 1 : 0

  name       = aws_config_configuration_recorder.environment[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.environment]
}

# ---------------------------------------------------------
# IAM ROLE - AWS Config Recorder (Requirement 20.5)
# ---------------------------------------------------------

resource "aws_iam_role" "config_recorder" {
  count = var.enable_config_rules ? 1 : 0

  name = "${var.platform_name}-${var.environment}-config-recorder-role"

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

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-config-recorder-role"
    Service = "aws-config"
  })
}

resource "aws_iam_role_policy_attachment" "config_recorder" {
  count = var.enable_config_rules ? 1 : 0

  role       = aws_iam_role.config_recorder[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3_delivery" {
  count = var.enable_config_rules ? 1 : 0

  name = "${var.platform_name}-${var.environment}-config-s3-delivery"
  role = aws_iam_role.config_recorder[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          "arn:aws:s3:::${var.cloudtrail_s3_bucket_name != "" ? var.cloudtrail_s3_bucket_name : "${var.platform_name}-${var.environment}-config-delivery"}",
          "arn:aws:s3:::${var.cloudtrail_s3_bucket_name != "" ? var.cloudtrail_s3_bucket_name : "${var.platform_name}-${var.environment}-config-delivery"}/${var.environment}/config/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
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
# EVENTBRIDGE RULE - Config Compliance Changes (Requirement 14.6)
# Alert when resources become non-compliant
# ---------------------------------------------------------

resource "aws_cloudwatch_event_rule" "config_compliance_change" {
  count = var.enable_config_rules ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-config-compliance-change"
  description = "Alerts on Config rule compliance status changes (Req 14.6)"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      messageType        = ["ComplianceChangeNotification"]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-config-compliance-rule"
    Service = "aws-config"
  })
}

resource "aws_cloudwatch_event_target" "config_compliance_to_sns" {
  count = var.enable_config_rules && var.security_notification_topic_arn != "" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.config_compliance_change[0].name
  target_id = "config-compliance-to-security-sns"
  arn       = var.security_notification_topic_arn
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "config_recorder_id" {
  description = "AWS Config recorder ID for this environment"
  value       = var.enable_config_rules ? aws_config_configuration_recorder.environment[0].id : null
}

output "encryption_conformance_pack_id" {
  description = "Encryption conformance pack ID"
  value       = var.enable_config_rules ? aws_config_conformance_pack.encryption[0].id : null
}

output "public_access_conformance_pack_id" {
  description = "Public access conformance pack ID"
  value       = var.enable_config_rules ? aws_config_conformance_pack.public_access[0].id : null
}

output "tagging_conformance_pack_id" {
  description = "Tagging compliance conformance pack ID"
  value       = var.enable_config_rules ? aws_config_conformance_pack.tagging[0].id : null
}

output "config_compliance_event_rule_arn" {
  description = "EventBridge rule ARN for Config compliance change notifications"
  value       = var.enable_config_rules ? aws_cloudwatch_event_rule.config_compliance_change[0].arn : null
}
