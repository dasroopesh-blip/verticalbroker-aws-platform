# Streaming Module Outputs
# VerticalBroker AWS Data Engineering Platform
#
# Exports Kinesis stream, EventBridge event bus, schema registry, SQS queue,
# and DLQ ARNs for consumption by other modules (compute, monitoring, security)
#
# Requirements: 1.3, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6

# ---------------------------------------------------------
# KINESIS DATA STREAM OUTPUTS
# ---------------------------------------------------------

output "market_data_stream_name" {
  description = "Name of the Kinesis market data stream"
  value       = aws_kinesis_stream.market_data.name
}

output "market_data_stream_arn" {
  description = "ARN of the Kinesis market data stream"
  value       = aws_kinesis_stream.market_data.arn
}

output "market_data_consumer_arn" {
  description = "ARN of the enhanced fan-out consumer for market data processor"
  value       = aws_kinesis_stream_consumer.market_data_processor.arn
}

# ---------------------------------------------------------
# EVENTBRIDGE EVENT BUS OUTPUTS
# ---------------------------------------------------------

output "event_bus_name" {
  description = "Name of the platform EventBridge event bus"
  value       = aws_cloudwatch_event_bus.platform.name
}

output "event_bus_arn" {
  description = "ARN of the platform EventBridge event bus"
  value       = aws_cloudwatch_event_bus.platform.arn
}


# ---------------------------------------------------------
# SCHEMA REGISTRY OUTPUTS
# ---------------------------------------------------------

output "schema_registry_name" {
  description = "Name of the EventBridge schema registry"
  value       = aws_schemas_registry.platform.name
}

output "schema_registry_arn" {
  description = "ARN of the EventBridge schema registry"
  value       = aws_schemas_registry.platform.arn
}

# ---------------------------------------------------------
# ROUTING RULE OUTPUTS
# ---------------------------------------------------------

output "event_rule_arns" {
  description = "Map of event type to EventBridge rule ARN"
  value = {
    data_ingested      = aws_cloudwatch_event_rule.data_ingested.arn
    trade_executed     = aws_cloudwatch_event_rule.trade_executed.arn
    pipeline_failed    = aws_cloudwatch_event_rule.pipeline_failed.arn
    compliance_alert   = aws_cloudwatch_event_rule.compliance_alert.arn
    advisory_generated = aws_cloudwatch_event_rule.advisory_generated.arn
  }
}

# ---------------------------------------------------------
# EVENT ARCHIVE OUTPUTS
# ---------------------------------------------------------

output "event_archive_name" {
  description = "Name of the unmatched events archive"
  value       = aws_cloudwatch_event_archive.unmatched_events.name
}

output "event_archive_arn" {
  description = "ARN of the unmatched events archive"
  value       = aws_cloudwatch_event_archive.unmatched_events.arn
}

# ---------------------------------------------------------
# EVENTBRIDGE DEAD-LETTER QUEUE OUTPUTS
# ---------------------------------------------------------

output "eventbridge_dlq_arn" {
  description = "ARN of the EventBridge dead-letter queue for failed deliveries"
  value       = aws_sqs_queue.eventbridge_dlq.arn
}

output "eventbridge_dlq_url" {
  description = "URL of the EventBridge dead-letter queue"
  value       = aws_sqs_queue.eventbridge_dlq.url
}


# ---------------------------------------------------------
# IAM ROLE OUTPUTS
# ---------------------------------------------------------

output "eventbridge_invoke_role_arn" {
  description = "ARN of the IAM role used by EventBridge to invoke targets"
  value       = aws_iam_role.eventbridge_invoke.arn
}

# ---------------------------------------------------------
# CLOUDWATCH LOG GROUP OUTPUTS
# ---------------------------------------------------------

output "pipeline_events_log_group_arn" {
  description = "ARN of the CloudWatch log group for pipeline failure events"
  value       = aws_cloudwatch_log_group.pipeline_events.arn
}

output "advisory_events_log_group_arn" {
  description = "ARN of the CloudWatch log group for advisory audit events"
  value       = aws_cloudwatch_log_group.advisory_events.arn
}

# ---------------------------------------------------------
# SQS QUEUE OUTPUTS
# ---------------------------------------------------------

output "sqs_queue_arns" {
  description = "Map of queue logical name to main queue ARN"
  value = {
    for name, queue in aws_sqs_queue.main :
    name => queue.arn
  }
}

output "sqs_queue_urls" {
  description = "Map of queue logical name to main queue URL"
  value = {
    for name, queue in aws_sqs_queue.main :
    name => queue.url
  }
}

output "sqs_dlq_arns" {
  description = "Map of queue logical name to DLQ ARN"
  value = {
    for name, queue in aws_sqs_queue.dlq :
    name => queue.arn
  }
}

output "trade_processing_queue_arn" {
  description = "ARN of the trade-processing FIFO queue"
  value       = aws_sqs_queue.main["trade-processing"].arn
}

output "trade_processing_queue_url" {
  description = "URL of the trade-processing FIFO queue"
  value       = aws_sqs_queue.main["trade-processing"].url
}

output "market_data_buffer_queue_arn" {
  description = "ARN of the market-data-buffer queue"
  value       = aws_sqs_queue.main["market-data-buffer"].arn
}


# ---------------------------------------------------------
# DMS CDC PIPELINE OUTPUTS
# Requirements: 5.1, 5.2, 5.3, 5.4, 5.6
# ---------------------------------------------------------

output "dms_replication_instance_arn" {
  description = "ARN of the DMS CDC replication instance"
  value       = aws_dms_replication_instance.cdc.replication_instance_arn
}

output "dms_replication_instance_id" {
  description = "Identifier of the DMS CDC replication instance"
  value       = aws_dms_replication_instance.cdc.replication_instance_id
}

output "dms_source_endpoint_arn" {
  description = "ARN of the DMS source endpoint (RDS/Aurora PostgreSQL)"
  value       = aws_dms_endpoint.source_postgresql.endpoint_arn
}

output "dms_target_endpoint_arn" {
  description = "ARN of the DMS target endpoint (S3 Bronze layer)"
  value       = aws_dms_endpoint.target_s3_bronze.endpoint_arn
}

output "dms_replication_task_arn" {
  description = "ARN of the DMS CDC replication task"
  value       = aws_dms_replication_task.cdc_trading.replication_task_arn
}

output "dms_replication_task_id" {
  description = "Identifier of the DMS CDC replication task"
  value       = aws_dms_replication_task.cdc_trading.replication_task_id
}

output "dms_replication_lag_alarm_arn" {
  description = "ARN of the CloudWatch alarm for DMS replication lag"
  value       = aws_cloudwatch_metric_alarm.dms_replication_lag.arn
}

output "dms_task_log_group_arn" {
  description = "ARN of the CloudWatch log group for DMS task logs"
  value       = aws_cloudwatch_log_group.dms_task_logs.arn
}
