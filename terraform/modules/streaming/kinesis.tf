# Kinesis Data Streams - Market Data Ingestion
# VerticalBroker AWS Data Engineering Platform
#
# Implements Kinesis Data Streams for real-time market data ingestion from
# Bloomberg B-Pipe and Thomson Reuters feeds.
#
# Design Parameters:
#   - Average throughput: 1,157 rec/sec (100M / 86,400)
#   - Burst throughput: 12,000 rec/sec (10x average)
#   - Average record size: 1 KB (market data payload + metadata)
#   - Write capacity per shard: 1,000 rec/sec or 1 MB/sec
#   - Required shards (burst): 12 shards (12,000 / 1,000)
#   - Provisioned shards: 16 (12 + 33% headroom)
#   - On-demand mode: enabled for auto-scaling beyond 16 for spikes
#   - Data retention: 168 hours (7 days) for replay capability
#   - Encryption: KMS using Confidential classification CMK
#   - Enhanced monitoring: shard-level metrics enabled
#
# Requirements: 1.3

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Stream name follows convention: vb-market-data-{environment}
  market_data_stream_name = var.market_data_stream_name != "" ? var.market_data_stream_name : "vb-market-data-${var.environment}"
}

# ---------------------------------------------------------
# KINESIS DATA STREAM - Market Data
# Requirement 1.3: Process burst rates of 12,000 records/sec without data loss
# ---------------------------------------------------------

resource "aws_kinesis_stream" "market_data" {
  name = local.market_data_stream_name

  # Retention period: 168 hours (7 days) for replay capability
  # Enables consumers to replay data for reprocessing or recovery scenarios
  retention_period = var.kinesis_retention_hours

  # Stream capacity mode: ON_DEMAND enables auto-scaling beyond provisioned base
  # This allows the stream to handle burst traffic (12,000 rec/sec) automatically
  # while scaling down during sustained average throughput (1,157 rec/sec)
  stream_mode_details {
    stream_mode = var.kinesis_stream_mode
  }

  # Encryption at rest using KMS CMK (Confidential classification)
  # Requirement 14.1: All data encrypted with classification-appropriate keys
  # Uses the Confidential CMK since market data contains trade information
  encryption_type = var.kinesis_encryption_type
  kms_key_id      = var.kinesis_encryption_type == "KMS" ? var.kms_key_arn : null

  # Enhanced shard-level monitoring metrics
  # Provides per-shard CloudWatch metrics for operational visibility:
  # - IncomingBytes/Records: monitor write throughput per shard
  # - OutgoingBytes/Records: monitor consumer read throughput per shard
  # - WriteProvisionedThroughputExceeded: detect hot shards needing redistribution
  # - ReadProvisionedThroughputExceeded: detect consumer bottlenecks
  # - IteratorAgeMilliseconds: detect consumer lag (critical for <5s ingestion SLA)
  shard_level_metrics = var.kinesis_enable_enhanced_monitoring ? var.kinesis_shard_level_metrics : []

  tags = merge(var.mandatory_tags, var.tags, {
    Name               = local.market_data_stream_name
    Service            = "kinesis"
    Component          = "market-data-ingestion"
    DataClassification = "Confidential"
    Purpose            = "real-time-market-data-streaming"
    DesignShardCount   = tostring(var.kinesis_shard_count)
    RetentionHours     = tostring(var.kinesis_retention_hours)
  })
}

# ---------------------------------------------------------
# KINESIS ENHANCED FAN-OUT CONSUMER
# Dedicated throughput for the market data processor Lambda
# Each enhanced fan-out consumer gets 2 MB/sec read per shard independently
# (vs. shared 2 MB/sec across all standard consumers)
# This ensures the Lambda processor does not contend with other consumers
# ---------------------------------------------------------

resource "aws_kinesis_stream_consumer" "market_data_processor" {
  name       = "${local.market_data_stream_name}-processor"
  stream_arn = aws_kinesis_stream.market_data.arn
}

# ---------------------------------------------------------
# CLOUDWATCH METRIC ALARMS - Kinesis Health Monitoring
# Requirement 15.2: Alarms for iterator age and throughput exceeded
# These alarms provide early warning for stream health issues
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name          = "${local.market_data_stream_name}-iterator-age-high"
  alarm_description   = "Kinesis iterator age exceeds 5 seconds - consumers falling behind on market data processing. Ingestion SLA at risk."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"
  period              = 60
  statistic           = "Maximum"
  threshold           = 5000 # 5 seconds in milliseconds - matches <5s ingestion SLA
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = aws_kinesis_stream.market_data.name
  }

  tags = merge(var.mandatory_tags, var.tags, {
    Name    = "${local.market_data_stream_name}-iterator-age-alarm"
    Service = "cloudwatch"
    Purpose = "kinesis-health-monitoring"
  })
}

resource "aws_cloudwatch_metric_alarm" "kinesis_write_throughput_exceeded" {
  alarm_name          = "${local.market_data_stream_name}-write-throughput-exceeded"
  alarm_description   = "Kinesis write provisioned throughput exceeded - stream capacity approaching limits, may need scaling review."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "WriteProvisionedThroughputExceeded"
  namespace           = "AWS/Kinesis"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = aws_kinesis_stream.market_data.name
  }

  tags = merge(var.mandatory_tags, var.tags, {
    Name    = "${local.market_data_stream_name}-write-exceeded-alarm"
    Service = "cloudwatch"
    Purpose = "kinesis-capacity-monitoring"
  })
}

resource "aws_cloudwatch_metric_alarm" "kinesis_read_throughput_exceeded" {
  alarm_name          = "${local.market_data_stream_name}-read-throughput-exceeded"
  alarm_description   = "Kinesis read provisioned throughput exceeded - consumers may need enhanced fan-out or additional capacity."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ReadProvisionedThroughputExceeded"
  namespace           = "AWS/Kinesis"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = aws_kinesis_stream.market_data.name
  }

  tags = merge(var.mandatory_tags, var.tags, {
    Name    = "${local.market_data_stream_name}-read-exceeded-alarm"
    Service = "cloudwatch"
    Purpose = "kinesis-capacity-monitoring"
  })
}
