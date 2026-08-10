# Per-Environment CloudTrail Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Purpose: Per-environment trail for data events (S3, Lambda, DynamoDB),
#          separate from the Organization trail in global/baseline_security.tf.
#          Stores logs in the Security & Audit account for FINRA compliance.
#
# Requirements: 14.5 (CloudTrail with dedicated compliance trail in separate security account)
# Requirements: 14.6 (Security event detection within 60 seconds)
# Requirements: 14.8 (SOC 2 Type II audit evidence - access logs)

# ---------------------------------------------------------
# DATA SOURCES
# Note: aws_caller_identity.current is defined in iam_roles.tf
# ---------------------------------------------------------

# ---------------------------------------------------------
# CLOUDTRAIL - Per-Environment Data Events Trail (Requirement 14.5)
# Captures all data-plane operations on S3, Lambda, and DynamoDB
# Separate from the Organization management trail for focused audit
# ---------------------------------------------------------

resource "aws_cloudtrail" "environment_data_events" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.platform_name}-${var.environment}-data-events-trail"
  s3_bucket_name                = var.cloudtrail_s3_bucket_name
  s3_key_prefix                 = "${var.environment}/data-events"
  is_organization_trail         = false
  is_multi_region_trail         = false
  include_global_service_events = false
  enable_log_file_validation    = true
  kms_key_id                    = var.cloudtrail_kms_key_arn != "" ? var.cloudtrail_kms_key_arn : null

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail_data_events[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cloudwatch[0].arn

  # S3 Data Events - Monitor all data bucket access
  event_selector {
    read_write_type           = "All"
    include_management_events = false

    dynamic "data_resource" {
      for_each = length(var.data_bucket_arns) > 0 ? var.data_bucket_arns : ["arn:aws:s3"]
      content {
        type   = "AWS::S3::Object"
        values = [length(var.data_bucket_arns) > 0 ? "${data_resource.value}/" : "arn:aws:s3"]
      }
    }
  }

  # Lambda Data Events - Monitor all function invocations
  event_selector {
    read_write_type           = "All"
    include_management_events = false

    dynamic "data_resource" {
      for_each = length(var.lambda_function_arns) > 0 ? var.lambda_function_arns : ["arn:aws:lambda"]
      content {
        type   = "AWS::Lambda::Function"
        values = [data_resource.value]
      }
    }
  }

  # DynamoDB Data Events - Monitor all table operations
  event_selector {
    read_write_type           = "All"
    include_management_events = false

    dynamic "data_resource" {
      for_each = length(var.dynamodb_table_arns) > 0 ? var.dynamodb_table_arns : ["arn:aws:dynamodb"]
      content {
        type   = "AWS::DynamoDB::Table"
        values = [data_resource.value]
      }
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-data-events-trail"
    Service = "cloudtrail"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH LOG GROUP - CloudTrail Data Events (Requirement 14.5)
# Local CloudWatch Logs for real-time metric filters and alarms
# ---------------------------------------------------------

resource "aws_cloudwatch_log_group" "cloudtrail_data_events" {
  count = var.enable_cloudtrail ? 1 : 0

  name              = "/aws/cloudtrail/${var.platform_name}-${var.environment}-data-events"
  retention_in_days = 90
  kms_key_id        = var.cloudtrail_kms_key_arn != "" ? var.cloudtrail_kms_key_arn : null

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-cloudtrail-logs"
    Service = "cloudtrail"
  })
}

# ---------------------------------------------------------
# IAM ROLE - CloudTrail → CloudWatch Logs Delivery
# ---------------------------------------------------------

resource "aws_iam_role" "cloudtrail_to_cloudwatch" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "${var.platform_name}-${var.environment}-cloudtrail-cw-role"

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

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-cloudtrail-cw-role"
    Service = "cloudtrail"
  })
}

resource "aws_iam_role_policy" "cloudtrail_to_cloudwatch" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "${var.platform_name}-${var.environment}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_to_cloudwatch[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail_data_events[0].arn}:*"
      }
    ]
  })
}

# ---------------------------------------------------------
# METRIC FILTERS - Detect Security Events (Requirement 14.6)
# Enable <60s detection of unauthorized access, privilege escalation,
# and data exfiltration patterns from CloudTrail data events.
# ---------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${var.platform_name}-${var.environment}-unauthorized-api-calls"
  log_group_name = aws_cloudwatch_log_group.cloudtrail_data_events[0].name
  pattern        = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"

  metric_transformation {
    name          = "UnauthorizedAPICalls"
    namespace     = "${var.platform_name}/${var.environment}/Security"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  count = var.enable_cloudtrail ? 1 : 0

  alarm_name          = "${var.platform_name}-${var.environment}-unauthorized-api-calls"
  alarm_description   = "Detects unauthorized API calls indicating potential access breach (Req 14.6)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICalls"
  namespace           = "${var.platform_name}/${var.environment}/Security"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = var.security_notification_topic_arn != "" ? [var.security_notification_topic_arn] : []

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-unauthorized-api-alarm"
    Service = "cloudtrail"
  })
}

resource "aws_cloudwatch_log_metric_filter" "s3_data_exfiltration" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${var.platform_name}-${var.environment}-s3-data-exfiltration"
  log_group_name = aws_cloudwatch_log_group.cloudtrail_data_events[0].name
  pattern        = "{ ($.eventSource = \"s3.amazonaws.com\") && (($.eventName = \"GetObject\") || ($.eventName = \"CopyObject\")) && ($.sourceIPAddress != \"*.amazonaws.com\") }"

  metric_transformation {
    name          = "S3DataExfiltrationAttempts"
    namespace     = "${var.platform_name}/${var.environment}/Security"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3_data_exfiltration" {
  count = var.enable_cloudtrail ? 1 : 0

  alarm_name          = "${var.platform_name}-${var.environment}-s3-data-exfiltration"
  alarm_description   = "Detects potential S3 data exfiltration patterns (Req 14.6)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "S3DataExfiltrationAttempts"
  namespace           = "${var.platform_name}/${var.environment}/Security"
  period              = 60
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  alarm_actions = var.security_notification_topic_arn != "" ? [var.security_notification_topic_arn] : []

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-s3-exfiltration-alarm"
    Service = "cloudtrail"
  })
}

resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${var.platform_name}-${var.environment}-iam-policy-changes"
  log_group_name = aws_cloudwatch_log_group.cloudtrail_data_events[0].name
  pattern        = "{ ($.eventName = \"DeleteGroupPolicy\") || ($.eventName = \"DeleteRolePolicy\") || ($.eventName = \"DeleteUserPolicy\") || ($.eventName = \"PutGroupPolicy\") || ($.eventName = \"PutRolePolicy\") || ($.eventName = \"PutUserPolicy\") || ($.eventName = \"CreatePolicy\") || ($.eventName = \"DeletePolicy\") || ($.eventName = \"CreatePolicyVersion\") || ($.eventName = \"DeletePolicyVersion\") || ($.eventName = \"AttachRolePolicy\") || ($.eventName = \"DetachRolePolicy\") || ($.eventName = \"AttachUserPolicy\") || ($.eventName = \"DetachUserPolicy\") || ($.eventName = \"AttachGroupPolicy\") || ($.eventName = \"DetachGroupPolicy\") }"

  metric_transformation {
    name          = "IAMPolicyChanges"
    namespace     = "${var.platform_name}/${var.environment}/Security"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_changes" {
  count = var.enable_cloudtrail ? 1 : 0

  alarm_name          = "${var.platform_name}-${var.environment}-iam-policy-changes"
  alarm_description   = "Detects IAM policy changes for privilege escalation detection (Req 14.6)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IAMPolicyChanges"
  namespace           = "${var.platform_name}/${var.environment}/Security"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.security_notification_topic_arn != "" ? [var.security_notification_topic_arn] : []

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-iam-changes-alarm"
    Service = "cloudtrail"
  })
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "cloudtrail_arn" {
  description = "Per-environment CloudTrail ARN for data events"
  value       = var.enable_cloudtrail ? aws_cloudtrail.environment_data_events[0].arn : null
}

output "cloudtrail_log_group_arn" {
  description = "CloudWatch Log Group ARN for CloudTrail data events"
  value       = var.enable_cloudtrail ? aws_cloudwatch_log_group.cloudtrail_data_events[0].arn : null
}

output "cloudtrail_log_group_name" {
  description = "CloudWatch Log Group name for CloudTrail data events"
  value       = var.enable_cloudtrail ? aws_cloudwatch_log_group.cloudtrail_data_events[0].name : null
}

output "unauthorized_api_calls_alarm_arn" {
  description = "CloudWatch alarm ARN for unauthorized API call detection"
  value       = var.enable_cloudtrail ? aws_cloudwatch_metric_alarm.unauthorized_api_calls[0].arn : null
}
