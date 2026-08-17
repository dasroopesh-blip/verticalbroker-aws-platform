# =============================================================================
# JUNIOR DEVELOPER'S TERRAFORM — Trade Processor Infrastructure
# =============================================================================
# This Terraform code deploys the Lambda trade processor with SQS, DynamoDB, S3.
# Contains multiple production-critical errors for peer review practice.
# =============================================================================

provider "aws" {
  region = "us-east-1"
}

# --- SQS Queue ---
resource "aws_sqs_queue" "trade_queue" {
  name                       = "trade-processing-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
}

# ERROR: No Dead Letter Queue configured!
# ERROR: visibility_timeout too low for Lambda timeout

# --- DynamoDB Orders Table ---
resource "aws_dynamodb_table" "orders" {
  name         = "verticalbroker-prod-orders"
  billing_mode = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  # ERROR: No point-in-time recovery
  # ERROR: No encryption specified
  # ERROR: Hardcoded low capacity with no autoscaling
}

# --- DynamoDB Idempotency Table ---
resource "aws_dynamodb_table" "idempotency" {
  name         = "verticalbroker-prod-idempotency"
  billing_mode = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  # ERROR: No TTL configuration!
  # ERROR: No encryption
}

# --- S3 Bucket ---
resource "aws_s3_bucket" "reports" {
  bucket = "verticalbroker-production-trade-reports"

  # ERROR: No versioning
  # ERROR: No encryption
  # ERROR: No lifecycle rules
  # ERROR: No public access block
}

# --- Lambda Function ---
resource "aws_lambda_function" "trade_processor" {
  function_name = "trade-processor"
  runtime       = "python3.9"
  handler       = "handler.lambda_handler"
  filename      = "lambda.zip"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 60
  memory_size   = 128

  environment {
    variables = {
      ORDERS_TABLE      = aws_dynamodb_table.orders.name
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      REPORT_BUCKET     = aws_s3_bucket.reports.bucket
    }
  }

  # ERROR: No reserved concurrency
  # ERROR: No dead letter config on Lambda
  # ERROR: Python 3.9 is EOL
  # ERROR: No tracing (X-Ray)
}

# --- IAM Role ---
resource "aws_iam_role" "lambda_role" {
  name = "trade-processor-role"

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
}

# ERROR: Wildcard permissions — violates least privilege
resource "aws_iam_role_policy" "lambda_policy" {
  name = "trade-processor-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:*"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- SQS Event Source Mapping ---
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.trade_queue.arn
  function_name    = aws_lambda_function.trade_processor.arn
  batch_size       = 100
  enabled          = true

  # ERROR: No function_response_types for ReportBatchItemFailures!
  # ERROR: batch_size=100 with no batching window
  # ERROR: No maximum_retry_attempts or failure destination
}

# --- NO OUTPUTS DEFINED ---
# ERROR: No outputs for cross-stack references
# ERROR: No CloudWatch alarms
# ERROR: No tags on any resource
