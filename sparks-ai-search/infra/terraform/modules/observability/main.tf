###############################################################################
# module: observability
# Purpose: make the system operable AND keep the Dev pilot inside its cost cap.
#
# Resources this module owns (fill in when approved):
#   - aws_cloudwatch_dashboard : latency (p50/p95), tokens in/out, est. cost,
#                                freshness lag, error/DLQ depth
#   - aws_cloudwatch_metric_alarm x N : latency SLO breach, error rate, DLQ depth,
#                                freshness lag > 20 min
#   - aws_budgets_budget        : HARD monthly cap (var.monthly_budget_usd) with
#                                 alerts at 50/80/100% -> SNS -> emails
#   - aws_sns_topic + subscriptions (budget_alert_emails)
#   - log-metric filters        : parse the Ask Lambda's structured "usage" logs
#                                 into token/cost metrics
###############################################################################

variable "name_prefix" { type = string }
variable "monthly_budget_usd" { type = number }
variable "budget_alert_emails" { type = list(string) }
variable "ask_lambda_name" { type = string }

output "dashboard_url" {
  description = "CloudWatch dashboard URL."
  value       = "https://console.aws.amazon.com/cloudwatch/home#dashboards:name=${var.name_prefix}" # placeholder
}
