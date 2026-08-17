# =============================================================================
# SENIOR DEVELOPER'S TERRAFORM — Trade Processor Infrastructure
# =============================================================================
# Production-ready Terraform for the Vertical Broker trade processor.
# Implements: least-privilege IAM, encryption at rest, DLQ, autoscaling,
# monitoring, ReportBatchItemFailures, tagging, and S3 hardening.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "verticalbroker-terraform-state"
    key            = "trade-processor/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# =============================================================================
# VARIABLES — No hardcoded values
# =============================================================================

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "lambda_memory_size" {
  description = "Lambda memory in MB"
  type        = number
  default     = 256
  validation {
    condition     = var.lambda_memory_size >= 128 && var.lambda_memory_size <= 3008
    error_message = "Lambda memory must be between 128 and 3008 MB."
  }
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 60
}

variable "sqs_batch_size" {
  description = "SQS batch size for Lambda trigger"
  type        = number
  default     = 10
}

variable "alarm_email" {
  description = "Email for CloudWatch alarm notifications"
  type        = string
  sensitive   = true
}

locals {
  project_name = "verticalbroker"
  service_name = "trade-processor"
  name_prefix  = "${local.project_name}-${var.environment}"

  common_tags = {
    Project     = local.project_name
    Service     = local.service_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

# =============================================================================
# SQS — Main Queue + Dead Letter Queue
# =============================================================================

resource "aws_sqs_queue" "trade_dlq" {
  name                      = "${local.name_prefix}-trade-dlq"
  message_retention_seconds = 1209600 # 14 days — maximum retention for investigation

  # Encryption at rest
  sqs_managed_sse_enabled = true

  tags = {
    Name = "${local.name_prefix}-trade-dlq"
  }
}

resource "aws_sqs_queue" "trade_queue" {
  name = "${local.name_prefix}-trade-queue"

  # Visibility timeout must be >= Lambda timeout × 6 (for retries)
  visibility_timeout_seconds = var.lambda_timeout * 6

  # Message retention: 4 days
  message_retention_seconds = 345600

  # Dead Letter Queue configuration
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.trade_dlq.arn
    maxReceiveCount     = 3
  })

  # Encryption at rest
  sqs_managed_sse_enabled = true

  tags = {
    Name = "${local.name_prefix}-trade-queue"
  }
}

# Allow DLQ to receive messages from main queue
resource "aws_sqs_queue_redrive_allow_policy" "dlq_allow" {
  queue_url = aws_sqs_queue.trade_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.trade_queue.arn]
  })
}

# =============================================================================
# DYNAMODB — Orders Table with autoscaling + encryption + PITR
# =============================================================================

resource "aws_dynamodb_table" "orders" {
  name         = "${local.name_prefix}-orders"
  billing_mode = "PAY_PER_REQUEST" # Auto-scales, no capacity planning needed
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  # Point-in-time recovery — critical for financial data
  point_in_time_recovery {
    enabled = true
  }

  # Encryption at rest with AWS-managed key
  server_side_encryption {
    enabled = true
  }

  # Deletion protection for production
  deletion_protection_enabled = var.environment == "prod" ? true : false

  tags = {
    Name        = "${local.name_prefix}-orders"
    DataClass   = "financial"
    BackupLevel = "critical"
  }
}

# =============================================================================
# DYNAMODB — Idempotency Table with TTL
# =============================================================================

resource "aws_dynamodb_table" "idempotency" {
  name         = "${local.name_prefix}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  # TTL — automatically delete expired idempotency records
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Encryption at rest
  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-idempotency"
  }
}

# =============================================================================
# S3 — Trade Reports Bucket (hardened)
# =============================================================================

resource "aws_s3_bucket" "reports" {
  bucket = "${local.name_prefix}-trade-reports"

  # Prevent accidental deletion in production
  force_destroy = var.environment != "prod"

  tags = {
    Name      = "${local.name_prefix}-trade-reports"
    DataClass = "financial"
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "archive-old-reports"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    # Retain for 7 years (regulatory requirement for financial records)
    expiration {
      days = 2555
    }
  }
}

# =============================================================================
# LAMBDA — Trade Processor Function
# =============================================================================

resource "aws_lambda_function" "trade_processor" {
  function_name = "${local.name_prefix}-trade-processor"
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  filename      = data.archive_file.lambda_zip.output_path
  role          = aws_iam_role.lambda_role.arn

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  # Reserved concurrency to prevent runaway scaling
  reserved_concurrent_executions = var.environment == "prod" ? 100 : 10

  # X-Ray tracing for distributed observability
  tracing_config {
    mode = "Active"
  }

  # Dead letter config (separate from SQS DLQ — for async invocation failures)
  dead_letter_config {
    target_arn = aws_sqs_queue.trade_dlq.arn
  }

  environment {
    variables = {
      ORDERS_TABLE              = aws_dynamodb_table.orders.name
      IDEMPOTENCY_TABLE         = aws_dynamodb_table.idempotency.name
      REPORT_BUCKET             = aws_s3_bucket.reports.bucket
      IDEMPOTENCY_TTL_SECONDS   = "86400"
      LOCK_STALENESS_SECONDS    = "300"
      LOG_LEVEL                 = var.environment == "prod" ? "INFO" : "DEBUG"
      ENVIRONMENT               = var.environment
      POWERTOOLS_SERVICE_NAME   = local.service_name
    }
  }

  tags = {
    Name = "${local.name_prefix}-trade-processor"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM — Least Privilege
# =============================================================================

resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-trade-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-trade-processor-role"
  }
}

# CloudWatch Logs — minimal permissions
resource "aws_iam_role_policy" "lambda_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
    }]
  })
}

# DynamoDB — only the specific actions needed on specific tables
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.orders.arn,
          aws_dynamodb_table.idempotency.arn
        ]
      }
    ]
  })
}

# S3 — only PutObject on the specific bucket and prefix
resource "aws_iam_role_policy" "lambda_s3" {
  name = "s3-reports"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject"
      ]
      Resource = "${aws_s3_bucket.reports.arn}/customers/*/trades/*"
    }]
  })
}

# SQS — only receive/delete on the specific queue
resource "aws_iam_role_policy" "lambda_sqs" {
  name = "sqs-receive"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.trade_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.trade_dlq.arn
      }
    ]
  })
}

# X-Ray tracing
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# =============================================================================
# SQS EVENT SOURCE MAPPING — With ReportBatchItemFailures
# =============================================================================

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.trade_queue.arn
  function_name    = aws_lambda_function.trade_processor.arn
  batch_size       = var.sqs_batch_size
  enabled          = true

  # CRITICAL: Enable partial batch failure reporting
  function_response_types = ["ReportBatchItemFailures"]

  # Maximum batching window — wait up to 5s to fill batch
  maximum_batching_window_in_seconds = 5

  # Scaling configuration
  scaling_config {
    maximum_concurrency = var.environment == "prod" ? 50 : 5
  }
}

# =============================================================================
# CLOUDWATCH — Logging and Alarms
# =============================================================================

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.name_prefix}-trade-processor"
  retention_in_days = var.environment == "prod" ? 90 : 14

  tags = {
    Name = "${local.name_prefix}-trade-processor-logs"
  }
}

# SNS Topic for alarms
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-trade-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Alarm: Lambda errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-trade-processor-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Trade processor Lambda error rate exceeded threshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.trade_processor.function_name
  }

  tags = {
    Name = "${local.name_prefix}-lambda-errors-alarm"
  }
}

# Alarm: DLQ messages (trades that exhausted retries)
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.name_prefix}-trade-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in trade DLQ — investigate failed trades!"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.trade_dlq.name
  }

  tags = {
    Name = "${local.name_prefix}-dlq-alarm"
  }
}

# Alarm: SQS queue depth (backlog building up)
resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  alarm_name          = "${local.name_prefix}-trade-queue-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 1000
  alarm_description   = "Trade queue backlog exceeds 1000 messages"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.trade_queue.name
  }

  tags = {
    Name = "${local.name_prefix}-queue-depth-alarm"
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "trade_queue_url" {
  description = "SQS queue URL for sending trade messages"
  value       = aws_sqs_queue.trade_queue.url
}

output "trade_queue_arn" {
  description = "SQS queue ARN"
  value       = aws_sqs_queue.trade_queue.arn
}

output "dlq_url" {
  description = "Dead letter queue URL for investigating failed trades"
  value       = aws_sqs_queue.trade_dlq.url
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.trade_processor.function_name
}

output "reports_bucket" {
  description = "S3 bucket for trade reports"
  value       = aws_s3_bucket.reports.bucket
}

output "lambda_role_arn" {
  description = "Lambda execution role ARN"
  value       = aws_iam_role.lambda_role.arn
}
