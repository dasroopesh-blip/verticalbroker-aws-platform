# Monitoring Module Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exposes monitoring resource identifiers for cross-module references.
# Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.7, 17.1, 17.3

# ---------------------------------------------------------
# SNS TOPIC OUTPUTS
# ---------------------------------------------------------

output "sns_topic_operations_arn" {
  description = "ARN of the operations SNS topic (PagerDuty integration)"
  value       = aws_sns_topic.operations.arn
}

output "sns_topic_operations_name" {
  description = "Name of the operations SNS topic"
  value       = aws_sns_topic.operations.name
}

output "sns_topic_security_arn" {
  description = "ARN of the security SNS topic (compliance team)"
  value       = aws_sns_topic.security.arn
}

output "sns_topic_security_name" {
  description = "Name of the security SNS topic"
  value       = aws_sns_topic.security.name
}

output "sns_topic_cost_arn" {
  description = "ARN of the cost SNS topic (finance team)"
  value       = aws_sns_topic.cost.arn
}

output "sns_topic_cost_name" {
  description = "Name of the cost SNS topic"
  value       = aws_sns_topic.cost.name
}

# ---------------------------------------------------------
# CLOUDWATCH DASHBOARD OUTPUTS
# ---------------------------------------------------------

output "dashboard_data_pipeline_health_arn" {
  description = "ARN of the data pipeline health dashboard"
  value       = aws_cloudwatch_dashboard.data_pipeline_health.dashboard_arn
}

output "dashboard_api_performance_arn" {
  description = "ARN of the API performance dashboard"
  value       = aws_cloudwatch_dashboard.api_performance.dashboard_arn
}


output "dashboard_cost_tracking_arn" {
  description = "ARN of the cost tracking dashboard"
  value       = aws_cloudwatch_dashboard.cost_tracking.dashboard_arn
}

output "dashboard_security_events_arn" {
  description = "ARN of the security events dashboard"
  value       = aws_cloudwatch_dashboard.security_events.dashboard_arn
}

output "dashboard_ml_model_performance_arn" {
  description = "ARN of the ML model performance dashboard"
  value       = aws_cloudwatch_dashboard.ml_model_performance.dashboard_arn
}

# ---------------------------------------------------------
# CLOUDWATCH ALARM OUTPUTS
# ---------------------------------------------------------

output "alarm_pipeline_latency_arn" {
  description = "ARN of the pipeline latency SLA breach alarm"
  value       = aws_cloudwatch_metric_alarm.pipeline_latency_sla_breach.arn
}

output "alarm_api_error_rate_arn" {
  description = "ARN of the API error rate alarm"
  value       = aws_cloudwatch_metric_alarm.api_error_rate_above_1pct.arn
}

output "alarm_lambda_throttling_arn" {
  description = "ARN of the Lambda throttling alarm"
  value       = aws_cloudwatch_metric_alarm.lambda_throttling_detected.arn
}

output "alarm_sqs_depth_arn" {
  description = "ARN of the SQS depth alarm"
  value       = aws_cloudwatch_metric_alarm.sqs_depth_above_10k.arn
}

output "alarm_cpu_utilization_arn" {
  description = "ARN of the infrastructure CPU alarm"
  value       = aws_cloudwatch_metric_alarm.infrastructure_cpu_above_80pct.arn
}

output "alarm_cdc_lag_arn" {
  description = "ARN of the CDC replication lag alarm"
  value       = aws_cloudwatch_metric_alarm.cdc_replication_lag_above_60s.arn
}

output "alarm_kinesis_iterator_age_arn" {
  description = "ARN of the Kinesis iterator age alarm"
  value       = aws_cloudwatch_metric_alarm.kinesis_iterator_age_above_5s.arn
}

output "alarm_glue_job_failure_arn" {
  description = "ARN of the Glue job failure alarm"
  value       = aws_cloudwatch_metric_alarm.glue_job_failure.arn
}

output "alarm_cost_budget_arn" {
  description = "ARN of the cost budget threshold alarm"
  value       = aws_cloudwatch_metric_alarm.cost_budget_80pct_threshold.arn
}


# ---------------------------------------------------------
# COMPOSITE ALARM OUTPUTS
# ---------------------------------------------------------

output "composite_alarm_data_pipeline_cascade_arn" {
  description = "ARN of the data pipeline cascade failure composite alarm"
  value       = aws_cloudwatch_composite_alarm.data_pipeline_cascade.arn
}

output "composite_alarm_api_compute_cascade_arn" {
  description = "ARN of the API + compute cascade failure composite alarm"
  value       = aws_cloudwatch_composite_alarm.api_compute_cascade.arn
}

output "composite_alarm_infrastructure_saturation_arn" {
  description = "ARN of the infrastructure saturation composite alarm"
  value       = aws_cloudwatch_composite_alarm.infrastructure_saturation.arn
}

# ---------------------------------------------------------
# X-RAY OUTPUTS
# ---------------------------------------------------------

output "xray_sampling_rule_normal_arn" {
  description = "ARN of the normal traffic X-Ray sampling rule"
  value       = aws_xray_sampling_rule.normal_traffic.arn
}

output "xray_sampling_rule_error_arn" {
  description = "ARN of the error path X-Ray sampling rule"
  value       = aws_xray_sampling_rule.error_paths.arn
}

output "xray_group_arns" {
  description = "Map of X-Ray group ARNs by service name"
  value = {
    market-data-ingestion = aws_xray_group.market_data_ingestion.arn
    order-manager         = aws_xray_group.order_manager.arn
    wallet-service        = aws_xray_group.wallet_service.arn
    advisory-agent        = aws_xray_group.advisory_agent.arn
    etl-pipeline          = aws_xray_group.etl_pipeline.arn
  }
}

# ---------------------------------------------------------
# SSM AUTOMATION OUTPUTS
# ---------------------------------------------------------

output "ssm_document_restart_pipeline_arn" {
  description = "ARN of the restart-failed-pipeline SSM Automation document"
  value       = aws_ssm_document.restart_failed_pipeline.arn
}

output "ssm_document_scale_capacity_arn" {
  description = "ARN of the scale-glue-capacity SSM Automation document"
  value       = aws_ssm_document.scale_glue_capacity.arn
}

output "ssm_document_rotate_credentials_arn" {
  description = "ARN of the rotate-credentials SSM Automation document"
  value       = aws_ssm_document.rotate_credentials.arn
}

output "ssm_automation_role_arn" {
  description = "ARN of the IAM role used by SSM Automation runbooks"
  value       = aws_iam_role.ssm_automation.arn
}


# ---------------------------------------------------------
# BUDGETS OUTPUTS
# ---------------------------------------------------------

output "budget_names" {
  description = "Map of CostCenter to budget names"
  value = {
    for k, v in aws_budgets_budget.cost_center : k => v.name
  }
}

output "budget_total_name" {
  description = "Name of the total platform budget"
  value       = aws_budgets_budget.platform_total.name
}

output "cost_reports_bucket_arn" {
  description = "ARN of the S3 bucket for Cost and Usage Reports"
  value       = aws_s3_bucket.cost_reports.arn
}

output "cost_reports_bucket_name" {
  description = "Name of the S3 bucket for Cost and Usage Reports"
  value       = aws_s3_bucket.cost_reports.id
}

# ---------------------------------------------------------
# KMS OUTPUTS
# ---------------------------------------------------------

output "sns_kms_key_arn" {
  description = "ARN of the KMS key used for SNS topic encryption"
  value       = local.sns_kms_key_arn
}

# ---------------------------------------------------------
# CONVENIENCE OUTPUTS
# ---------------------------------------------------------

output "all_sns_topic_arns" {
  description = "All SNS topic ARNs for use in alarm configurations"
  value = {
    operations = aws_sns_topic.operations.arn
    security   = aws_sns_topic.security.arn
    cost       = aws_sns_topic.cost.arn
  }
}

output "all_alarm_arns" {
  description = "All CloudWatch alarm ARNs"
  value = {
    pipeline_latency  = aws_cloudwatch_metric_alarm.pipeline_latency_sla_breach.arn
    api_error_rate    = aws_cloudwatch_metric_alarm.api_error_rate_above_1pct.arn
    lambda_throttling = aws_cloudwatch_metric_alarm.lambda_throttling_detected.arn
    sqs_depth         = aws_cloudwatch_metric_alarm.sqs_depth_above_10k.arn
    cpu_utilization   = aws_cloudwatch_metric_alarm.infrastructure_cpu_above_80pct.arn
    cdc_lag           = aws_cloudwatch_metric_alarm.cdc_replication_lag_above_60s.arn
    kinesis_iterator  = aws_cloudwatch_metric_alarm.kinesis_iterator_age_above_5s.arn
    glue_failure      = aws_cloudwatch_metric_alarm.glue_job_failure.arn
    cost_budget       = aws_cloudwatch_metric_alarm.cost_budget_80pct_threshold.arn
  }
}
