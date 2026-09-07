# ===========================================================================
# Compute module: the indexing worker Lambda, triggered by SQS.
#
# LEARNING NOTE: The worker reads jobs off the SQS queue, embeds chunks via
# Bedrock, and indexes them into OpenSearch. An "event source mapping" connects
# the queue to the Lambda so AWS invokes it automatically as messages arrive.
# We run it inside the VPC so it can reach the private OpenSearch/RDS endpoints.
#
# NOTE: the deployment package (worker.zip) is built by scripts/build-lambda.sh
# and produced from src/filings_assistant. A placeholder path is referenced here
# so `terraform plan` is understandable; build the zip before `apply`.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "lambda_role_arn" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "opensearch_endpoint" {
  type = string
}

variable "environment_vars" {
  type = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_lambda_function" "worker" {
  function_name = "${var.name_prefix}-worker"
  role          = var.lambda_role_arn
  runtime       = "python3.12"
  handler       = "filings_assistant.worker.processor.lambda_handler"
  timeout       = 30
  memory_size   = 512

  # Build this artifact with `make package` / scripts/build-lambda.sh.
  filename = "${path.module}/artifacts/worker.zip"

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = var.environment_vars
  }

  tags = var.tags

  # Ignore code hash drift so `plan` isn't noisy before the zip is built.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# Connect the SQS queue to the Lambda (SQS invokes the worker per batch).
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = var.queue_arn
  function_name                      = aws_lambda_function.worker.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 10
  function_response_types            = ["ReportBatchItemFailures"]
}

output "worker_function_name" {
  value = aws_lambda_function.worker.function_name
}
