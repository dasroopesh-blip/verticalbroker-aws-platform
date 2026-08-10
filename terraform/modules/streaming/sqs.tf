# SQS Queues and Dead-Letter Queues
# VerticalBroker AWS Data Engineering Platform
#
# Implements Amazon SQS queues for asynchronous message processing with:
# - FIFO queues with content-based deduplication for trade ordering (Requirement 6.4)
# - Dead-letter queues with configurable max receive counts (Requirement 6.5)
# - KMS encryption using Confidential CMK for all queues (Requirement 14.1)
# - Long polling (20s receive wait) on standard queues
# - Per-queue visibility timeouts matching processing requirements
# - 14-day retention for critical queues (Requirement 1.4)
#
# Queue inventory:
#   trade-processing.fifo   - FIFO, ordered trade event processing
#   market-data-buffer      - Standard, market data buffering when sources unavailable
#   etl-trigger             - Standard, ETL pipeline trigger events
#   advisory-requests       - Standard, advisory recommendation requests
#   compliance-events.fifo  - FIFO, ordered compliance event processing
#
# Requirements: 6.4, 6.5, 1.4

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Queue configuration map: defines all queues with their properties
  sqs_queues = {
    trade-processing = {
      fifo                        = true
      visibility_timeout_seconds  = 30
      message_retention_seconds   = 1209600 # 14 days
      max_receive_count           = 5
      content_based_deduplication = true
      receive_wait_time_seconds   = 0 # FIFO queues use short polling by default
      description                 = "Ordered trade event processing with exactly-once delivery"
    }
    market-data-buffer = {
      fifo                        = false
      visibility_timeout_seconds  = 60
      message_retention_seconds   = 1209600 # 14 days
      max_receive_count           = 3
      content_based_deduplication = false
      receive_wait_time_seconds   = 20 # Long polling for standard queues
      description                 = "Market data buffering when sources are unavailable"
    }
    etl-trigger = {
      fifo                        = false
      visibility_timeout_seconds  = 300
      message_retention_seconds   = 345600 # 4 days
      max_receive_count           = 3
      content_based_deduplication = false
      receive_wait_time_seconds   = 20 # Long polling for standard queues
      description                 = "ETL pipeline trigger events"
    }
    advisory-requests = {
      fifo                        = false
      visibility_timeout_seconds  = 30
      message_retention_seconds   = 345600 # 4 days
      max_receive_count           = 5
      content_based_deduplication = false
      receive_wait_time_seconds   = 20 # Long polling for standard queues
      description                 = "Advisory recommendation request processing"
    }
    compliance-events = {
      fifo                        = true
      visibility_timeout_seconds  = 60
      message_retention_seconds   = 1209600 # 14 days
      max_receive_count           = 5
      content_based_deduplication = true
      receive_wait_time_seconds   = 0 # FIFO queues use short polling by default
      description                 = "Ordered compliance event processing with exactly-once delivery"
    }
  }

  # Derived queue names (with .fifo suffix for FIFO queues)
  queue_names = {
    for name, config in local.sqs_queues :
    name => config.fifo ? "${var.name_prefix}-${name}.fifo" : "${var.name_prefix}-${name}"
  }

  # DLQ names follow convention: {prefix}-{name}-dlq[.fifo]
  dlq_names = {
    for name, config in local.sqs_queues :
    name => config.fifo ? "${var.name_prefix}-${name}-dlq.fifo" : "${var.name_prefix}-${name}-dlq"
  }
}

# ---------------------------------------------------------
# DEAD-LETTER QUEUES (DLQs)
# Requirement 6.5: DLQs with 14-day retention for failed messages
# Must be created before main queues for redrive policy reference
# ---------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  for_each = local.sqs_queues

  name = local.dlq_names[each.key]

  # FIFO configuration for DLQs must match their parent queue type
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo ? true : null

  # DLQ retention: 14 days to allow investigation before message loss
  message_retention_seconds = 1209600 # 14 days

  # DLQ visibility timeout matches parent queue
  visibility_timeout_seconds = each.value.visibility_timeout_seconds

  # KMS encryption using Confidential CMK (Requirement 14.1)
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  # Mandatory tags (Requirement 13.5)
  tags = merge(var.mandatory_tags, {
    Name               = local.dlq_names[each.key]
    Service            = "sqs"
    Purpose            = "dead-letter-queue"
    ParentQueue        = local.queue_names[each.key]
    DataClassification = "Confidential"
    QueueType          = each.value.fifo ? "FIFO" : "Standard"
  })
}

# ---------------------------------------------------------
# MAIN SQS QUEUES
# Requirement 6.4: FIFO queues for ordered trade processing
# Requirement 6.5: DLQ redrive policy with maxReceiveCount
# Requirement 1.4: 14-day retention for market data buffering
# ---------------------------------------------------------

resource "aws_sqs_queue" "main" {
  for_each = local.sqs_queues

  name = local.queue_names[each.key]

  # Queue type configuration
  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.fifo ? each.value.content_based_deduplication : null

  # FIFO queues: enable high throughput mode for better performance
  deduplication_scope   = each.value.fifo ? "messageGroup" : null
  fifo_throughput_limit = each.value.fifo ? "perMessageGroupId" : null

  # Visibility timeout: time a message is hidden after being received
  visibility_timeout_seconds = each.value.visibility_timeout_seconds

  # Message retention period
  message_retention_seconds = each.value.message_retention_seconds

  # Long polling: reduces empty responses and API calls (standard queues only)
  receive_wait_time_seconds = each.value.receive_wait_time_seconds

  # Maximum message size: 256 KB (default)
  max_message_size = 262144

  # Delay: no delivery delay
  delay_seconds = 0

  # KMS encryption using Confidential CMK (Requirement 14.1)
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  # Redrive policy: route failed messages to DLQ after max receive count
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  # Mandatory tags (Requirement 13.5)
  tags = merge(var.mandatory_tags, {
    Name               = local.queue_names[each.key]
    Service            = "sqs"
    Purpose            = each.value.description
    DataClassification = "Confidential"
    QueueType          = each.value.fifo ? "FIFO" : "Standard"
  })
}

# ---------------------------------------------------------
# REDRIVE ALLOW POLICIES
# Restrict which queues can use each DLQ as a dead-letter target
# ---------------------------------------------------------

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.sqs_queues

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

# ---------------------------------------------------------
# SQS QUEUE POLICIES
# Allow EventBridge and Lambda to send messages to queues
# ---------------------------------------------------------

resource "aws_sqs_queue_policy" "main" {
  for_each = local.sqs_queues

  queue_url = aws_sqs_queue.main[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.queue_names[each.key]}-policy"
    Statement = [
      {
        Sid    = "AllowEventBridgeSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main[each.key].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:aws:events:${var.aws_region}:${var.aws_account_id}:rule/${var.eventbridge_bus_name}/*"
          }
        }
      },
      {
        Sid    = "AllowSNSSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main[each.key].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.main[each.key].arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS FOR QUEUE DEPTH MONITORING
# Requirement 15.2: Alarm when queue depth exceeds 10,000 messages
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  for_each = local.sqs_queues

  alarm_name          = "${local.queue_names[each.key]}-depth-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.queue_depth_alarm_threshold
  alarm_description   = "Queue depth exceeds ${var.queue_depth_alarm_threshold} messages for ${local.queue_names[each.key]}"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = local.queue_names[each.key]
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, {
    Name    = "${local.queue_names[each.key]}-depth-alarm"
    Service = "cloudwatch"
    Purpose = "queue-depth-monitoring"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS FOR DLQ MESSAGES (any message in DLQ = alert)
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  for_each = local.sqs_queues

  alarm_name          = "${local.dlq_names[each.key]}-messages-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages detected in dead-letter queue ${local.dlq_names[each.key]} - investigate failed message processing"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = local.dlq_names[each.key]
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, {
    Name    = "${local.dlq_names[each.key]}-messages-alarm"
    Service = "cloudwatch"
    Purpose = "dlq-monitoring"
  })
}
