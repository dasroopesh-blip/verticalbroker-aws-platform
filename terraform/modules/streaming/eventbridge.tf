# EventBridge Event Bus, Schema Registry, Routing Rules, and Archive
# VerticalBroker AWS Data Engineering Platform
#
# Implements event-driven architecture with:
#   - Custom event bus: verticalbroker-platform
#   - Schema Registry with auto-discovery
#   - Routing rules for domain events
#   - Event archive for unmatched events (30-day retention)
#   - Dead-letter queue for failed event delivery
#   - CloudWatch metrics for event delivery failures
#
# Requirements: 6.1 (EventBridge with schema registry enforcement)
# Requirements: 6.2 (Event patterns: data.ingested, trade.executed, pipeline.failed, compliance.alert, advisory.generated)
# Requirements: 6.3 (Deliver events to matching subscribers within 1 second)
# Requirements: 6.6 (Route unmatched events to archive for debugging)

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  eventbridge_name_prefix = "${var.name_prefix}-platform"

  eventbridge_tags = merge(var.mandatory_tags, var.tags, {
    Component = "EventBridge"
    Module    = "streaming"
  })
}


# ---------------------------------------------------------
# EVENT BUS
# Requirement 6.1: Route domain events using Amazon EventBridge
# ---------------------------------------------------------

resource "aws_cloudwatch_event_bus" "platform" {
  name = local.eventbridge_name_prefix

  tags = merge(local.eventbridge_tags, {
    Name = local.eventbridge_name_prefix
  })
}

# ---------------------------------------------------------
# SCHEMA REGISTRY WITH AUTO-DISCOVERY
# Requirement 6.1: Schema registry enforcement
# ---------------------------------------------------------

resource "aws_schemas_registry" "platform" {
  name        = "${var.name_prefix}-event-schemas"
  description = "VerticalBroker platform event schema registry with auto-discovery"

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-event-schemas"
  })
}

resource "aws_schemas_discoverer" "platform" {
  source_arn  = aws_cloudwatch_event_bus.platform.arn
  description = "Auto-discovers event schemas from the verticalbroker-platform event bus"

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-schema-discoverer"
  })
}


# ---------------------------------------------------------
# SCHEMA DEFINITIONS
# Requirement 6.2: Event patterns for domain events
# ---------------------------------------------------------

resource "aws_schemas_schema" "data_ingested" {
  name          = "verticalbroker.market-data@MarketDataIngested"
  registry_name = aws_schemas_registry.platform.name
  type          = "OpenApi3"
  description   = "Schema for data.ingested events from Market Data Ingestion Service"

  content = jsonencode({
    openapi = "3.0.0"
    info = {
      title   = "MarketDataIngested"
      version = "1.0.0"
    }
    paths = {}
    components = {
      schemas = {
        MarketDataIngested = {
          type = "object"
          properties = {
            source_id           = { type = "string" }
            partition_path      = { type = "string" }
            record_count        = { type = "integer" }
            ingestion_timestamp = { type = "string", format = "date-time" }
            schema_version      = { type = "string" }
            size_bytes          = { type = "integer" }
          }
          required = ["source_id", "partition_path", "record_count", "ingestion_timestamp"]
        }
      }
    }
  })

  tags = local.eventbridge_tags
}


resource "aws_schemas_schema" "trade_executed" {
  name          = "verticalbroker.order-manager@TradeExecuted"
  registry_name = aws_schemas_registry.platform.name
  type          = "OpenApi3"
  description   = "Schema for trade.executed events from Order Manager"

  content = jsonencode({
    openapi = "3.0.0"
    info = {
      title   = "TradeExecuted"
      version = "1.0.0"
    }
    paths = {}
    components = {
      schemas = {
        TradeExecuted = {
          type = "object"
          properties = {
            order_id            = { type = "string", format = "uuid" }
            client_id           = { type = "string" }
            instrument_id       = { type = "string" }
            side                = { type = "string", enum = ["BUY", "SELL"] }
            quantity            = { type = "number" }
            executed_price      = { type = "number" }
            execution_timestamp = { type = "string", format = "date-time" }
            venue               = { type = "string" }
          }
          required = ["order_id", "client_id", "instrument_id", "side", "quantity", "executed_price", "execution_timestamp"]
        }
      }
    }
  })

  tags = local.eventbridge_tags
}


resource "aws_schemas_schema" "pipeline_failed" {
  name          = "verticalbroker.etl-engine@PipelineExecutionFailed"
  registry_name = aws_schemas_registry.platform.name
  type          = "OpenApi3"
  description   = "Schema for pipeline.failed events from ETL Engine"

  content = jsonencode({
    openapi = "3.0.0"
    info = {
      title   = "PipelineExecutionFailed"
      version = "1.0.0"
    }
    paths = {}
    components = {
      schemas = {
        PipelineExecutionFailed = {
          type = "object"
          properties = {
            job_id              = { type = "string" }
            pipeline_stage      = { type = "string", enum = ["bronze-to-silver", "silver-to-gold"] }
            error_type          = { type = "string" }
            error_message       = { type = "string" }
            retry_count         = { type = "integer" }
            affected_partitions = { type = "array", items = { type = "string" } }
            failure_timestamp   = { type = "string", format = "date-time" }
          }
          required = ["job_id", "pipeline_stage", "error_type", "error_message", "retry_count", "failure_timestamp"]
        }
      }
    }
  })

  tags = local.eventbridge_tags
}


resource "aws_schemas_schema" "compliance_alert" {
  name          = "verticalbroker.security@ComplianceAlert"
  registry_name = aws_schemas_registry.platform.name
  type          = "OpenApi3"
  description   = "Schema for compliance.alert events from Security services"

  content = jsonencode({
    openapi = "3.0.0"
    info = {
      title   = "ComplianceAlert"
      version = "1.0.0"
    }
    paths = {}
    components = {
      schemas = {
        ComplianceAlert = {
          type = "object"
          properties = {
            alert_id            = { type = "string", format = "uuid" }
            severity            = { type = "string", enum = ["HIGH", "MEDIUM", "LOW"] }
            alert_type          = { type = "string" }
            source_account      = { type = "string" }
            resource_arn        = { type = "string" }
            description         = { type = "string" }
            detection_timestamp = { type = "string", format = "date-time" }
          }
          required = ["alert_id", "severity", "alert_type", "description", "detection_timestamp"]
        }
      }
    }
  })

  tags = local.eventbridge_tags
}


resource "aws_schemas_schema" "advisory_generated" {
  name          = "verticalbroker.advisory-agent@AdvisoryGenerated"
  registry_name = aws_schemas_registry.platform.name
  type          = "OpenApi3"
  description   = "Schema for advisory.generated events from Advisory Agent"

  content = jsonencode({
    openapi = "3.0.0"
    info = {
      title   = "AdvisoryGenerated"
      version = "1.0.0"
    }
    paths = {}
    components = {
      schemas = {
        AdvisoryGenerated = {
          type = "object"
          properties = {
            recommendation_id    = { type = "string", format = "uuid" }
            client_id            = { type = "string" }
            model_version        = { type = "string" }
            confidence_score     = { type = "number" }
            requires_human_review = { type = "boolean" }
            timestamp            = { type = "string", format = "date-time" }
          }
          required = ["recommendation_id", "client_id", "model_version", "confidence_score", "timestamp"]
        }
      }
    }
  })

  tags = local.eventbridge_tags
}


# ---------------------------------------------------------
# ROUTING RULES
# Requirement 6.3: Deliver events to matching subscribers within 1 second
# ---------------------------------------------------------

# Rule 1: data.ingested → Step Functions (ETL Orchestrator)
resource "aws_cloudwatch_event_rule" "data_ingested" {
  name           = "${var.name_prefix}-data-ingested"
  description    = "Routes MarketDataIngested events to Step Functions ETL orchestrator"
  event_bus_name = aws_cloudwatch_event_bus.platform.name

  event_pattern = jsonencode({
    source      = ["verticalbroker.market-data"]
    detail-type = ["MarketDataIngested"]
  })

  tags = merge(local.eventbridge_tags, {
    Name      = "${var.name_prefix}-data-ingested"
    EventType = "data.ingested"
  })
}

resource "aws_cloudwatch_event_target" "data_ingested_sfn" {
  rule           = aws_cloudwatch_event_rule.data_ingested.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "etl-orchestrator"
  arn            = var.step_functions_arn
  role_arn       = aws_iam_role.eventbridge_invoke.arn

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}


# Rule 2: trade.executed → SQS FIFO (trade-processing.fifo)
resource "aws_cloudwatch_event_rule" "trade_executed" {
  name           = "${var.name_prefix}-trade-executed"
  description    = "Routes TradeExecuted events to SQS FIFO for ordered processing"
  event_bus_name = aws_cloudwatch_event_bus.platform.name

  event_pattern = jsonencode({
    source      = ["verticalbroker.order-manager"]
    detail-type = ["TradeExecuted"]
  })

  tags = merge(local.eventbridge_tags, {
    Name      = "${var.name_prefix}-trade-executed"
    EventType = "trade.executed"
  })
}

resource "aws_cloudwatch_event_target" "trade_executed_sqs" {
  rule           = aws_cloudwatch_event_rule.trade_executed.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "trade-processing-fifo"
  arn            = var.trade_processing_queue_arn

  sqs_target {
    message_group_id = "trade-events"
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}


# Rule 3: pipeline.failed → CloudWatch Logs + SNS notification
resource "aws_cloudwatch_event_rule" "pipeline_failed" {
  name           = "${var.name_prefix}-pipeline-failed"
  description    = "Routes PipelineExecutionFailed events to CloudWatch Logs and SNS"
  event_bus_name = aws_cloudwatch_event_bus.platform.name

  event_pattern = jsonencode({
    source      = ["verticalbroker.etl-engine"]
    detail-type = ["PipelineExecutionFailed"]
  })

  tags = merge(local.eventbridge_tags, {
    Name      = "${var.name_prefix}-pipeline-failed"
    EventType = "pipeline.failed"
  })
}

resource "aws_cloudwatch_log_group" "pipeline_events" {
  name              = "/aws/events/${var.name_prefix}/pipeline-failures"
  retention_in_days = var.log_retention_days

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-pipeline-failure-logs"
  })
}

resource "aws_cloudwatch_event_target" "pipeline_failed_logs" {
  rule           = aws_cloudwatch_event_rule.pipeline_failed.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "pipeline-failure-logs"
  arn            = aws_cloudwatch_log_group.pipeline_events.arn

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

resource "aws_cloudwatch_event_target" "pipeline_failed_sns" {
  rule           = aws_cloudwatch_event_rule.pipeline_failed.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "pipeline-failure-sns"
  arn            = var.operations_sns_topic_arn

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}


# Rule 4: compliance.alert → SNS (security team)
resource "aws_cloudwatch_event_rule" "compliance_alert" {
  name           = "${var.name_prefix}-compliance-alert"
  description    = "Routes ComplianceAlert events to SNS for security team notification"
  event_bus_name = aws_cloudwatch_event_bus.platform.name

  event_pattern = jsonencode({
    source      = ["verticalbroker.security"]
    detail-type = ["ComplianceAlert"]
  })

  tags = merge(local.eventbridge_tags, {
    Name      = "${var.name_prefix}-compliance-alert"
    EventType = "compliance.alert"
  })
}

resource "aws_cloudwatch_event_target" "compliance_alert_sns" {
  rule           = aws_cloudwatch_event_rule.compliance_alert.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "security-team-sns"
  arn            = var.security_sns_topic_arn

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}


# Rule 5: advisory.generated → CloudWatch Logs (audit)
resource "aws_cloudwatch_event_rule" "advisory_generated" {
  name           = "${var.name_prefix}-advisory-generated"
  description    = "Routes AdvisoryGenerated events to CloudWatch Logs for audit trail"
  event_bus_name = aws_cloudwatch_event_bus.platform.name

  event_pattern = jsonencode({
    source      = ["verticalbroker.advisory-agent"]
    detail-type = ["AdvisoryGenerated"]
  })

  tags = merge(local.eventbridge_tags, {
    Name      = "${var.name_prefix}-advisory-generated"
    EventType = "advisory.generated"
  })
}

resource "aws_cloudwatch_log_group" "advisory_events" {
  name              = "/aws/events/${var.name_prefix}/advisory-audit"
  retention_in_days = var.log_retention_days

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-advisory-audit-logs"
  })
}

resource "aws_cloudwatch_event_target" "advisory_generated_logs" {
  rule           = aws_cloudwatch_event_rule.advisory_generated.name
  event_bus_name = aws_cloudwatch_event_bus.platform.name
  target_id      = "advisory-audit-logs"
  arn            = aws_cloudwatch_log_group.advisory_events.arn

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}


# ---------------------------------------------------------
# EVENT ARCHIVE FOR UNMATCHED EVENTS
# Requirement 6.6: Route unmatched events to archive for debugging
# ---------------------------------------------------------

resource "aws_cloudwatch_event_archive" "unmatched_events" {
  name             = "${var.name_prefix}-unmatched-events"
  description      = "Archive for events that match no rules (30-day retention for debugging)"
  event_source_arn = aws_cloudwatch_event_bus.platform.arn
  retention_days   = var.event_archive_retention_days

  # Archive all events - unmatched events are captured here as a catch-all
  event_pattern = jsonencode({
    account = [var.aws_account_id]
  })
}

# ---------------------------------------------------------
# DEAD-LETTER QUEUE FOR FAILED EVENT DELIVERY
# Ensures no events are lost when targets are unavailable
# ---------------------------------------------------------

resource "aws_sqs_queue" "eventbridge_dlq" {
  name                       = "${var.name_prefix}-eventbridge-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20

  # Enable server-side encryption
  sqs_managed_sse_enabled = true

  tags = merge(local.eventbridge_tags, {
    Name    = "${var.name_prefix}-eventbridge-dlq"
    Purpose = "EventBridge failed delivery dead-letter queue"
  })
}

resource "aws_sqs_queue_policy" "eventbridge_dlq" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeSendMessage"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.eventbridge_dlq.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_bus.platform.arn
          }
        }
      }
    ]
  })
}


# ---------------------------------------------------------
# IAM ROLE FOR EVENTBRIDGE TARGETS
# Allows EventBridge to invoke Step Functions and other targets
# ---------------------------------------------------------

resource "aws_iam_role" "eventbridge_invoke" {
  name = "${var.name_prefix}-eventbridge-invoke"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-eventbridge-invoke"
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_sfn" {
  name = "${var.name_prefix}-eventbridge-invoke-sfn"
  role = aws_iam_role.eventbridge_invoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowStepFunctionsExecution"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = var.step_functions_arn
      }
    ]
  })
}


# ---------------------------------------------------------
# CLOUDWATCH LOG RESOURCE POLICIES
# Allow EventBridge to write to CloudWatch Log Groups
# ---------------------------------------------------------

resource "aws_cloudwatch_log_resource_policy" "eventbridge_logs" {
  policy_name     = "${var.name_prefix}-eventbridge-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeToWriteLogs"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.pipeline_events.arn}:*",
          "${aws_cloudwatch_log_group.advisory_events.arn}:*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------
# CLOUDWATCH METRICS AND ALARMS
# Monitor event delivery failures and DLQ depth
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "eventbridge_dlq_depth" {
  alarm_name          = "${var.name_prefix}-eventbridge-dlq-depth"
  alarm_description   = "Alert when EventBridge DLQ has messages (failed event delivery)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.eventbridge_dlq.name
  }

  alarm_actions = [var.operations_sns_topic_arn]
  ok_actions    = [var.operations_sns_topic_arn]

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-eventbridge-dlq-depth-alarm"
  })
}


resource "aws_cloudwatch_metric_alarm" "eventbridge_failed_invocations" {
  alarm_name          = "${var.name_prefix}-eventbridge-failed-invocations"
  alarm_description   = "Alert when EventBridge rules have failed invocations"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    EventBusName = aws_cloudwatch_event_bus.platform.name
  }

  alarm_actions = [var.operations_sns_topic_arn]
  ok_actions    = [var.operations_sns_topic_arn]

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-eventbridge-failed-invocations-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "eventbridge_throttled" {
  alarm_name          = "${var.name_prefix}-eventbridge-throttled"
  alarm_description   = "Alert when EventBridge rules are being throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRules"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    EventBusName = aws_cloudwatch_event_bus.platform.name
  }

  alarm_actions = [var.operations_sns_topic_arn]
  ok_actions    = [var.operations_sns_topic_arn]

  tags = merge(local.eventbridge_tags, {
    Name = "${var.name_prefix}-eventbridge-throttled-alarm"
  })
}
