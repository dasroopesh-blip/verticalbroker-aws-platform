# ===========================================================================
# Monitoring module: AWS Budgets cost alarm + SNS email alerts.
#
# LEARNING NOTE: This is your financial safety net. AWS Budgets watches monthly
# spend and publishes to an SNS topic when you cross thresholds (50% and 90% of
# the budget). You get an email so an idle OpenSearch domain never surprises
# you. This directly supports the "stay under budget" goal.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "monthly_budget_usd" {
  type = number
}

variable "alert_email" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# SNS topic that alerts are published to.
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
  tags = var.tags
}

# Email subscription (you must confirm the subscription via the email link).
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# The monthly cost budget with two notification thresholds.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
