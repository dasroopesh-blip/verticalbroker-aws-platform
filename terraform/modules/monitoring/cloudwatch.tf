# CloudWatch Dashboards and Alarms
# VerticalBroker AWS Data Engineering Platform
#
# Implements comprehensive monitoring with:
# - 5 Dashboards: data-pipeline-health, api-performance, cost-tracking,
#   security-events, ml-model-performance
# - Critical alarms for SLA breach detection
# - Composite alarms for cascading failure detection
#
# Requirements: 15.1, 15.2, 15.4

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  dashboard_prefix = "${var.name_prefix}-monitoring"
  alarm_prefix     = "${var.name_prefix}-alarm"
}

# ---------------------------------------------------------
# CLOUDWATCH DASHBOARDS
# ---------------------------------------------------------

# Dashboard 1: Data Pipeline Health
resource "aws_cloudwatch_dashboard" "data_pipeline_health" {
  dashboard_name = "${local.dashboard_prefix}-data-pipeline-health"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Pipeline Latency (Bronze → Silver → Gold)"
          region  = var.aws_region
          metrics = [
            ["VerticalBroker/ETL", "ProcessingDurationSeconds", "JobName", "bronze-to-silver", { stat = "Average" }],
            ["VerticalBroker/ETL", "ProcessingDurationSeconds", "JobName", "silver-to-gold", { stat = "Average" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Records Processed (Input/Output/Rejected)"
          region  = var.aws_region
          metrics = [
            ["VerticalBroker/ETL", "RecordsInput", "Stage", "bronze-to-silver", { stat = "Sum" }],
            ["VerticalBroker/ETL", "RecordsOutput", "Stage", "bronze-to-silver", { stat = "Sum" }],
            ["VerticalBroker/ETL", "RecordsRejected", "Stage", "bronze-to-silver", { stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Kinesis Iterator Age"
          region  = var.aws_region
          metrics = [
            ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds", "StreamName", "${var.name_prefix}-market-data", { stat = "Maximum" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "SQS Queue Depth"
          region  = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-trade-processing.fifo", { stat = "Maximum" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-market-data-buffer", { stat = "Maximum" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
    ]
  })
}


# Dashboard 2: API Performance
resource "aws_cloudwatch_dashboard" "api_performance" {
  dashboard_name = "${local.dashboard_prefix}-api-performance"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "API Gateway Latency (P50/P90/P99)"
          region  = var.aws_region
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, { stat = "p50" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, { stat = "p90" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, { stat = "p99" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "API Error Rates (4xx / 5xx)"
          region  = var.aws_region
          metrics = [
            ["AWS/ApiGateway", "4xx", "ApiId", var.api_gateway_id, { stat = "Sum" }],
            ["AWS/ApiGateway", "5xx", "ApiId", var.api_gateway_id, { stat = "Sum" }],
            ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, { stat = "Sum" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title   = "Lambda Duration by Function"
          region  = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-market-data-processor", { stat = "Average" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-order-manager", { stat = "Average" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-advisory-agent", { stat = "Average" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
    ]
  })
}


# Dashboard 3: Cost Tracking
resource "aws_cloudwatch_dashboard" "cost_tracking" {
  dashboard_name = "${local.dashboard_prefix}-cost-tracking"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Estimated Charges by Service"
          region  = "us-east-1"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "ServiceName", "AmazonS3", { stat = "Maximum" }],
            ["AWS/Billing", "EstimatedCharges", "ServiceName", "AWSGlue", { stat = "Maximum" }],
            ["AWS/Billing", "EstimatedCharges", "ServiceName", "AWSLambda", { stat = "Maximum" }],
            ["AWS/Billing", "EstimatedCharges", "ServiceName", "AmazonKinesis", { stat = "Maximum" }],
          ]
          period = 86400
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Total Estimated Charges"
          region  = "us-east-1"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD", { stat = "Maximum" }],
          ]
          period = 86400
          view   = "singleValue"
        }
      },
    ]
  })
}


# Dashboard 4: Security Events
resource "aws_cloudwatch_dashboard" "security_events" {
  dashboard_name = "${local.dashboard_prefix}-security-events"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title   = "Security Events (CloudTrail)"
          region  = var.aws_region
          query   = "SOURCE '/aws/cloudtrail' | fields @timestamp, eventName, userIdentity.arn, sourceIPAddress | filter errorCode like /Unauthorized|AccessDenied|Forbidden/ | sort @timestamp desc | limit 50"
          view    = "table"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "GuardDuty Findings"
          region  = var.aws_region
          metrics = [
            ["AWS/GuardDuty", "FindingsCount", { stat = "Sum" }],
          ]
          period = 3600
          view   = "timeSeries"
        }
      },
    ]
  })
}


# Dashboard 5: ML Model Performance
resource "aws_cloudwatch_dashboard" "ml_model_performance" {
  dashboard_name = "${local.dashboard_prefix}-ml-model-performance"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "SageMaker Endpoint Invocations & Latency"
          region  = var.aws_region
          metrics = [
            ["AWS/SageMaker", "Invocations", "EndpointName", "${var.name_prefix}-advisory-endpoint", { stat = "Sum" }],
            ["AWS/SageMaker", "ModelLatency", "EndpointName", "${var.name_prefix}-advisory-endpoint", { stat = "Average" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Model Error Rate & Low-Confidence Recommendations"
          region  = var.aws_region
          metrics = [
            ["VerticalBroker/Advisory", "InvocationErrors", { stat = "Sum" }],
            ["VerticalBroker/Advisory", "LowConfidenceCount", { stat = "Sum" }],
            ["VerticalBroker/Advisory", "HumanReviewRequired", { stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
    ]
  })
}


# ---------------------------------------------------------
# CLOUDWATCH ALARMS - Critical SLA and Operational Alerts
# Requirement 15.2: Alarms for pipeline latency, error rates,
# throttling, queue depth, CPU, CDC lag, iterator age, Glue failures
# ---------------------------------------------------------

# Alarm 1: Pipeline Latency SLA Breach
resource "aws_cloudwatch_metric_alarm" "pipeline_latency_sla_breach" {
  alarm_name          = "${local.alarm_prefix}-pipeline-latency-sla-breach"
  alarm_description   = "ETL pipeline processing duration exceeds SLA threshold of ${var.pipeline_latency_sla_seconds}s"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  metric_name         = "ProcessingDurationSeconds"
  namespace           = "VerticalBroker/ETL"
  statistic           = "Average"
  period              = 300
  threshold           = var.pipeline_latency_sla_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = "bronze-to-silver"
  }

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-pipeline-latency-sla-breach"
  })
}


# Alarm 2: API Error Rate Above 1%
resource "aws_cloudwatch_metric_alarm" "api_error_rate_above_1pct" {
  alarm_name          = "${local.alarm_prefix}-api-error-rate-above-1pct"
  alarm_description   = "API Gateway 5xx error rate exceeds ${var.api_error_rate_threshold_pct}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  threshold           = var.api_error_rate_threshold_pct
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "(errors / requests) * 100"
    label       = "Error Rate %"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      metric_name = "5xx"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions = {
        ApiId = var.api_gateway_id
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      metric_name = "Count"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions = {
        ApiId = var.api_gateway_id
      }
    }
  }

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-api-error-rate-above-1pct"
  })
}


# Alarm 3: Lambda Throttling Detected
resource "aws_cloudwatch_metric_alarm" "lambda_throttling_detected" {
  alarm_name          = "${local.alarm_prefix}-lambda-throttling-detected"
  alarm_description   = "Lambda function throttling detected - reserved concurrency may be exhausted"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  period              = 60
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-lambda-throttling-detected"
  })
}

# Alarm 4: SQS Queue Depth Above 10K
resource "aws_cloudwatch_metric_alarm" "sqs_depth_above_10k" {
  alarm_name          = "${local.alarm_prefix}-sqs-depth-above-10k"
  alarm_description   = "SQS queue depth exceeds ${var.sqs_depth_threshold} messages - processing may be backed up"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  period              = 60
  threshold           = var.sqs_depth_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-trade-processing.fifo"
  }

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-sqs-depth-above-10k"
  })
}


# Alarm 5: Infrastructure CPU Above 80%
resource "aws_cloudwatch_metric_alarm" "infrastructure_cpu_above_80pct" {
  alarm_name          = "${local.alarm_prefix}-infrastructure-cpu-above-80pct"
  alarm_description   = "Infrastructure CPU utilization exceeds ${var.cpu_utilization_threshold_pct}% - auto-scaling or capacity review needed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  metric_name         = "CPUUtilization"
  namespace           = "AWS/Neptune"
  statistic           = "Average"
  period              = 300
  threshold           = var.cpu_utilization_threshold_pct
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-infrastructure-cpu-above-80pct"
  })
}

# Alarm 6: CDC Replication Lag Above 60s
resource "aws_cloudwatch_metric_alarm" "cdc_replication_lag_above_60s" {
  alarm_name          = "${local.alarm_prefix}-cdc-replication-lag-above-60s"
  alarm_description   = "DMS CDC replication lag exceeds ${var.cdc_replication_lag_threshold_seconds}s threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  metric_name         = "CDCLatencySource"
  namespace           = "AWS/DMS"
  statistic           = "Average"
  period              = 60
  threshold           = var.cdc_replication_lag_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = var.dms_replication_instance_id
  }

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-cdc-replication-lag-above-60s"
  })
}


# Alarm 7: Kinesis Iterator Age Above 5s
resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age_above_5s" {
  alarm_name          = "${local.alarm_prefix}-kinesis-iterator-age-above-5s"
  alarm_description   = "Kinesis iterator age exceeds ${var.kinesis_iterator_age_threshold_ms}ms - consumers are falling behind"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_datapoints_to_alarm
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"
  statistic           = "Maximum"
  period              = 60
  threshold           = var.kinesis_iterator_age_threshold_ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = var.kinesis_stream_name
  }

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-kinesis-iterator-age-above-5s"
  })
}

# Alarm 8: Glue Job Failure
resource "aws_cloudwatch_metric_alarm" "glue_job_failure" {
  alarm_name          = "${local.alarm_prefix}-glue-job-failure"
  alarm_description   = "Glue ETL job has failed - check job logs and retry status"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "AWS/Glue"
  statistic           = "Sum"
  period              = 300
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-glue-job-failure"
  })
}


# Alarm 9: Cost Budget 80% Threshold
resource "aws_cloudwatch_metric_alarm" "cost_budget_80pct_threshold" {
  alarm_name          = "${local.alarm_prefix}-cost-budget-80pct-threshold"
  alarm_description   = "Monthly spend has exceeded 80% of allocated budget"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  statistic           = "Maximum"
  period              = 21600
  threshold           = tonumber(var.budget_limit_amount) * (var.budget_threshold_pct / 100)
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.cost.arn]
  ok_actions    = [aws_sns_topic.cost.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-cost-budget-80pct-threshold"
  })
}

# ---------------------------------------------------------
# COMPOSITE ALARMS - Cascading Failure Detection
# Detects when multiple related alarms fire simultaneously,
# indicating a systemic issue rather than isolated failures.
# ---------------------------------------------------------

# Composite Alarm: Data Pipeline Cascade Failure
# Triggers when pipeline latency AND queue depth both breach
resource "aws_cloudwatch_composite_alarm" "data_pipeline_cascade" {
  alarm_name        = "${local.alarm_prefix}-data-pipeline-cascade-failure"
  alarm_description = "Cascading failure detected: pipeline latency SLA breach coincides with SQS queue buildup and/or Kinesis consumer lag"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.pipeline_latency_sla_breach.alarm_name}) AND (ALARM(${aws_cloudwatch_metric_alarm.sqs_depth_above_10k.alarm_name}) OR ALARM(${aws_cloudwatch_metric_alarm.kinesis_iterator_age_above_5s.alarm_name}))"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-data-pipeline-cascade-failure"
  })
}


# Composite Alarm: API + Compute Cascade Failure
# Triggers when API errors AND Lambda throttling both occur
resource "aws_cloudwatch_composite_alarm" "api_compute_cascade" {
  alarm_name        = "${local.alarm_prefix}-api-compute-cascade-failure"
  alarm_description = "Cascading failure detected: API error rate breach coincides with Lambda throttling - compute capacity may be exhausted"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.api_error_rate_above_1pct.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.lambda_throttling_detected.alarm_name})"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-api-compute-cascade-failure"
  })
}

# Composite Alarm: Infrastructure Saturation
# Triggers when CPU is high AND CDC lag is increasing
resource "aws_cloudwatch_composite_alarm" "infrastructure_saturation" {
  alarm_name        = "${local.alarm_prefix}-infrastructure-saturation"
  alarm_description = "Infrastructure saturation detected: high CPU utilization with CDC replication lag - capacity scaling required"

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.infrastructure_cpu_above_80pct.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.cdc_replication_lag_above_60s.alarm_name})"

  alarm_actions = [aws_sns_topic.operations.arn]
  ok_actions    = [aws_sns_topic.operations.arn]

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${local.alarm_prefix}-infrastructure-saturation"
  })
}
