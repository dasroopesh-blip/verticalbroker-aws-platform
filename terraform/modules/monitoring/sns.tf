# SNS Alerting and Notification Topics
# VerticalBroker AWS Data Engineering Platform
#
# Implements notification infrastructure with:
# - 3 SNS Topics: operations (PagerDuty), security (compliance team), cost (finance)
# - KMS encryption on all topics
# - Subscription configurations for email and HTTPS endpoints
#
# Requirements: 15.3, 17.1, 17.3

# ---------------------------------------------------------
# KMS KEY FOR SNS ENCRYPTION
# ---------------------------------------------------------

resource "aws_kms_key" "sns_encryption" {
  count = var.sns_kms_key_arn == "" ? 1 : 0

  description             = "KMS key for SNS topic encryption - ${var.name_prefix}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSService"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },

      {
        Sid    = "AllowBudgetsService"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-sns-encryption-key"
  })
}

resource "aws_kms_alias" "sns_encryption" {
  count = var.sns_kms_key_arn == "" ? 1 : 0

  name          = "alias/${var.name_prefix}-sns-encryption"
  target_key_id = aws_kms_key.sns_encryption[0].key_id
}

locals {
  sns_kms_key_arn = var.sns_kms_key_arn != "" ? var.sns_kms_key_arn : aws_kms_key.sns_encryption[0].arn
}

# ---------------------------------------------------------
# SNS TOPIC 1: Operations (PagerDuty Integration)
# Receives critical operational alarms for immediate response.
# Requirement 15.3: Notify operations via SNS within 60 seconds
# ---------------------------------------------------------

resource "aws_sns_topic" "operations" {
  name              = "${var.name_prefix}-monitoring-operations"
  display_name      = "VerticalBroker Operations Alerts"
  kms_master_key_id = local.sns_kms_key_arn

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-monitoring-operations"
  })
}


resource "aws_sns_topic_policy" "operations" {
  arn = aws_sns_topic.operations.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.operations.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid       = "AllowSSMAutomation"
        Effect    = "Allow"
        Principal = { Service = "ssm.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.operations.arn
      },
    ]
  })
}

# PagerDuty HTTPS subscription (if endpoint provided)
resource "aws_sns_topic_subscription" "operations_pagerduty" {
  count = var.pagerduty_endpoint_url != "" ? 1 : 0

  topic_arn = aws_sns_topic.operations.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint_url

  endpoint_auto_confirms = true
}

# Email subscriptions for operations team
resource "aws_sns_topic_subscription" "operations_email" {
  for_each = toset(var.operations_email_endpoints)

  topic_arn = aws_sns_topic.operations.arn
  protocol  = "email"
  endpoint  = each.value
}


# ---------------------------------------------------------
# SNS TOPIC 2: Security (Compliance Team)
# Receives security alerts, compliance violations, and audit events.
# Requirement 14.6, 15.3: Security event notifications
# ---------------------------------------------------------

resource "aws_sns_topic" "security" {
  name              = "${var.name_prefix}-monitoring-security"
  display_name      = "VerticalBroker Security Alerts"
  kms_master_key_id = local.sns_kms_key_arn

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-monitoring-security"
  })
}

resource "aws_sns_topic_policy" "security" {
  arn = aws_sns_topic.security.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security.arn
      },
      {
        Sid       = "AllowGuardDuty"
        Effect    = "Allow"
        Principal = { Service = "guardduty.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security.arn
      },
    ]
  })
}

# Email subscriptions for security/compliance team
resource "aws_sns_topic_subscription" "security_email" {
  for_each = toset(var.security_email_endpoints)

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = each.value
}


# ---------------------------------------------------------
# SNS TOPIC 3: Cost (Finance Team)
# Receives budget threshold alerts and cost anomaly notifications.
# Requirements: 17.1, 17.3
# ---------------------------------------------------------

resource "aws_sns_topic" "cost" {
  name              = "${var.name_prefix}-monitoring-cost"
  display_name      = "VerticalBroker Cost Alerts"
  kms_master_key_id = local.sns_kms_key_arn

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-monitoring-cost"
  })
}

resource "aws_sns_topic_policy" "cost" {
  arn = aws_sns_topic.cost.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBudgets"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.cost.arn
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.cost.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid       = "AllowCostExplorer"
        Effect    = "Allow"
        Principal = { Service = "ce.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.cost.arn
      },
    ]
  })
}

# Email subscriptions for finance team
resource "aws_sns_topic_subscription" "cost_email" {
  for_each = toset(var.finance_email_endpoints)

  topic_arn = aws_sns_topic.cost.arn
  protocol  = "email"
  endpoint  = each.value
}
