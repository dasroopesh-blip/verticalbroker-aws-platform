# AWS Budgets Cost Management
# VerticalBroker AWS Data Engineering Platform
#
# Implements cost controls with:
# - AWS Budgets per CostCenter tag
# - 80% threshold alerts to finance SNS topic
# - Monthly cost allocation reports via Cost and Usage Reports
#
# Requirements: 17.1, 17.3

# ---------------------------------------------------------
# AWS BUDGETS PER COSTCENTER TAG
# Creates one budget per CostCenter with 80% threshold alerting
# ---------------------------------------------------------

resource "aws_budgets_budget" "cost_center" {
  for_each = var.cost_center_budgets

  name         = "${var.name_prefix}-budget-${each.key}"
  budget_type  = "COST"
  limit_amount = each.value
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:CostCenter$${each.key}"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_threshold_pct
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  # Forecasted spend alert at 100%
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  tags = merge(var.mandatory_tags, {
    Service    = "monitoring"
    CostCenter = each.key
    Name       = "${var.name_prefix}-budget-${each.key}"
  })
}


# ---------------------------------------------------------
# OVERALL PLATFORM BUDGET
# Aggregate budget for the entire platform spend
# ---------------------------------------------------------

resource "aws_budgets_budget" "platform_total" {
  name         = "${var.name_prefix}-budget-total"
  budget_type  = "COST"
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_threshold_pct
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 90
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost.arn]
  }

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-budget-total"
  })
}

# ---------------------------------------------------------
# COST AND USAGE REPORT
# Monthly cost allocation reports broken down by pipeline,
# environment, and team using AWS Cost and Usage Reports
# Requirement 17.6
# ---------------------------------------------------------

resource "aws_cur_report_definition" "monthly_cost_report" {
  report_name                = "${var.name_prefix}-monthly-cost-report"
  time_unit                  = "MONTHLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES", "SPLIT_COST_ALLOCATION_DATA"]
  s3_bucket                  = "${var.name_prefix}-cost-reports"
  s3_region                  = var.aws_region
  s3_prefix                  = "cost-and-usage-reports"
  report_versioning          = "OVERWRITE_REPORT"
  refresh_closed_reports     = true

  additional_artifacts = ["ATHENA"]
}


# S3 bucket for Cost and Usage Reports
resource "aws_s3_bucket" "cost_reports" {
  bucket = "${var.name_prefix}-cost-reports"

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-cost-reports"
  })
}

resource "aws_s3_bucket_versioning" "cost_reports" {
  bucket = aws_s3_bucket.cost_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cost_reports" {
  bucket = aws_s3_bucket.cost_reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.sns_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cost_reports" {
  bucket = aws_s3_bucket.cost_reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cost_reports" {
  bucket = aws_s3_bucket.cost_reports.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCURService"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy",
        ]
        Resource = aws_s3_bucket.cost_reports.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid    = "AllowCURWrite"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cost_reports.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
    ]
  })
}
