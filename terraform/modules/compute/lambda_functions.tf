# Lambda Functions - VerticalBroker AWS Data Engineering Platform
#
# Defines all Lambda functions with environment variables, VPC config, layers,
# event source mappings, and associated permissions.
#
# Functions:
#   1. market-data-processor   - Kinesis event source, reserved 2000, provisioned 500
#   2. order-manager           - API Gateway integration, reserved 1000, provisioned 200
#   3. wallet-service-api      - API Gateway integration, memory 512MB
#   4. wallet-service-sqs      - SQS FIFO event source (trade-processing.fifo), memory 512MB
#   5. advisory-agent          - API Gateway integration, reserved 500, provisioned 100
#   6. dlq-processor           - SQS event source (various DLQs), memory 256MB
#   7. outbox-publisher        - DynamoDB Streams event source (OrderOutbox), memory 256MB
#
# Requirements: 7.1, 7.2, 7.3, 7.4
# Requirement 7.1: Python 3.12 runtime, Lambda Powertools
# Requirement 7.2: 30s timeout for API handlers, 900s for async processors
# Requirement 7.3: Lambda Layers for shared dependencies
# Requirement 7.4: Reserved/provisioned concurrency for critical functions

# =============================================================================
# LOCAL VALUES
# =============================================================================

locals {
  # Common Lambda configuration
  lambda_runtime      = "python3.12"
  lambda_architecture = "arm64" # Graviton2: 20% cost reduction + 34% performance

  # Common environment variables for all functions
  common_environment_variables = {
    ENVIRONMENT       = var.environment
    BRONZE_BUCKET     = var.bronze_bucket_name
    SILVER_BUCKET     = var.silver_bucket_name
    GOLD_BUCKET       = var.gold_bucket_name
    EVENT_BUS_NAME    = var.event_bus_name
    LOG_LEVEL         = var.environment == "production" ? "INFO" : "DEBUG"
    POWERTOOLS_SERVICE_NAME = "verticalbroker"
    POWERTOOLS_METRICS_NAMESPACE = "VerticalBroker"
  }

  # Lambda function definitions map
  lambda_functions = {
    market-data-processor = {
      description          = "Processes real-time market data from Kinesis streams into Bronze layer"
      handler              = "services.market_data.handler.lambda_handler"
      memory_size          = 1024
      timeout              = 900
      reserved_concurrency = 2000
      provisioned_concurrency = 500
      role_arn             = var.market_data_lambda_role_arn
      environment_variables = {
        IDEMPOTENCY_TABLE      = aws_dynamodb_table.idempotency_store.name
        GLUE_DATABASE          = var.bronze_database_name
        GLUE_TABLE             = "market_data_raw"
        DLQ_URL                = var.market_data_dlq_url
        BATCH_SIZE             = "100"
        POWERTOOLS_SERVICE_NAME = "market-data-ingestion"
      }
    }
    order-manager = {
      description          = "Handles order lifecycle: validation, execution, settlement via API Gateway"
      handler              = "services.order_manager.handler.lambda_handler"
      memory_size          = 512
      timeout              = 30
      reserved_concurrency = 1000
      provisioned_concurrency = 200
      role_arn             = var.order_manager_role_arn
      environment_variables = {
        IDEMPOTENCY_TABLE       = aws_dynamodb_table.idempotency_store.name
        ORDERS_TABLE            = aws_dynamodb_table.orders.name
        ORDER_OUTBOX_TABLE      = aws_dynamodb_table.order_outbox.name
        CIRCUIT_BREAKER_TABLE   = aws_dynamodb_table.circuit_breaker_state.name
        POWERTOOLS_SERVICE_NAME = "order-manager"
      }
    }
    wallet-service-api = {
      description          = "Portfolio and margin queries via API Gateway"
      handler              = "services.wallet.handler.lambda_handler"
      memory_size          = 512
      timeout              = 30
      reserved_concurrency = null
      provisioned_concurrency = null
      role_arn             = var.wallet_service_role_arn
      environment_variables = {
        PORTFOLIO_TABLE         = aws_dynamodb_table.portfolio.name
        CIRCUIT_BREAKER_TABLE   = aws_dynamodb_table.circuit_breaker_state.name
        POWERTOOLS_SERVICE_NAME = "wallet-service"
      }
    }
    wallet-service-sqs = {
      description          = "Processes trade events from SQS FIFO to update portfolio positions"
      handler              = "services.wallet.sqs_handler.lambda_handler"
      memory_size          = 512
      timeout              = 900
      reserved_concurrency = null
      provisioned_concurrency = null
      role_arn             = var.wallet_service_role_arn
      environment_variables = {
        PORTFOLIO_TABLE         = aws_dynamodb_table.portfolio.name
        IDEMPOTENCY_TABLE       = aws_dynamodb_table.idempotency_store.name
        CIRCUIT_BREAKER_TABLE   = aws_dynamodb_table.circuit_breaker_state.name
        POWERTOOLS_SERVICE_NAME = "wallet-service-sqs"
      }
    }
    advisory-agent = {
      description          = "RL-based advisory recommendations via API Gateway with FINRA compliance logging"
      handler              = "services.advisory_agent.handler.lambda_handler"
      memory_size          = 1024
      timeout              = 30
      reserved_concurrency = 500
      provisioned_concurrency = 100
      role_arn             = var.advisory_agent_role_arn
      environment_variables = {
        SAGEMAKER_ENDPOINT      = var.sagemaker_endpoint_name
        REGULATORY_BUCKET       = var.regulatory_bucket_name
        IDEMPOTENCY_TABLE       = aws_dynamodb_table.idempotency_store.name
        CONFIDENCE_THRESHOLD    = "0.7"
        POWERTOOLS_SERVICE_NAME = "advisory-agent"
      }
    }
    dlq-processor = {
      description          = "Processes messages from various dead-letter queues for investigation and retry"
      handler              = "services.dlq_processor.handler.lambda_handler"
      memory_size          = 256
      timeout              = 900
      reserved_concurrency = null
      provisioned_concurrency = null
      role_arn             = var.dlq_processor_role_arn
      environment_variables = {
        POWERTOOLS_SERVICE_NAME = "dlq-processor"
      }
    }
    outbox-publisher = {
      description          = "Publishes domain events from DynamoDB Streams OrderOutbox to EventBridge"
      handler              = "services.outbox_publisher.handler.lambda_handler"
      memory_size          = 256
      timeout              = 900
      reserved_concurrency = null
      provisioned_concurrency = null
      role_arn             = var.outbox_publisher_role_arn
      environment_variables = {
        POWERTOOLS_SERVICE_NAME = "outbox-publisher"
      }
    }
  }

  # Mandatory tags for all Lambda resources
  lambda_tags = merge(var.mandatory_tags, {
    Service = "Compute"
  })
}

# =============================================================================
# LAMBDA FUNCTIONS
# =============================================================================

resource "aws_lambda_function" "functions" {
  for_each = local.lambda_functions

  function_name = "${var.name_prefix}-${each.key}"
  description   = each.value.description
  role          = each.value.role_arn

  # Deployment package
  s3_bucket = var.artifacts_bucket_name
  s3_key    = "lambda-packages/${each.key}/${var.lambda_package_version}/package.zip"

  # Runtime configuration
  runtime       = local.lambda_runtime
  architectures = [local.lambda_architecture]
  handler       = each.value.handler
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout

  # Reserved concurrency (null means unreserved)
  reserved_concurrent_executions = each.value.reserved_concurrency

  # Lambda Layers (Requirement 7.3)
  layers = [
    aws_lambda_layer_version.shared_dependencies.arn,
    aws_lambda_layer_version.common_utilities.arn,
    aws_lambda_layer_version.data_models.arn,
  ]

  # VPC configuration - all functions run in private compute subnets (Requirement 20.3)
  vpc_config {
    subnet_ids         = var.compute_subnet_ids
    security_group_ids = [var.compute_security_group_id]
  }

  # Environment variables
  environment {
    variables = merge(local.common_environment_variables, each.value.environment_variables)
  }

  # X-Ray tracing (Requirement 15.5)
  tracing_config {
    mode = "Active"
  }

  # Dead-letter configuration (Requirement 7.6)
  dead_letter_config {
    target_arn = var.function_dlq_arns[each.key]
  }

  # Publish versioned functions for alias-based deployments
  publish = true

  tags = merge(local.lambda_tags, {
    Function           = each.key
    DataClassification = "Confidential"
  })

  depends_on = [
    aws_dynamodb_table.idempotency_store,
    aws_dynamodb_table.circuit_breaker_state,
  ]
}

# =============================================================================
# PROVISIONED CONCURRENCY (Requirement 7.4)
# Only for latency-sensitive functions with provisioned concurrency configured
# =============================================================================

resource "aws_lambda_alias" "live" {
  for_each = local.lambda_functions

  name             = "live"
  description      = "Live alias for ${each.key} function"
  function_name    = aws_lambda_function.functions[each.key].function_name
  function_version = aws_lambda_function.functions[each.key].version
}

resource "aws_lambda_provisioned_concurrency_config" "critical" {
  for_each = {
    for key, config in local.lambda_functions :
    key => config if config.provisioned_concurrency != null
  }

  function_name                  = aws_lambda_function.functions[each.key].function_name
  qualifier                      = aws_lambda_alias.live[each.key].name
  provisioned_concurrent_executions = each.value.provisioned_concurrency
}

# =============================================================================
# EVENT SOURCE MAPPING: KINESIS -> MarketDataProcessor
# Requirement 7.4: Batch size 100, parallelization factor 10
# =============================================================================

resource "aws_lambda_event_source_mapping" "kinesis_market_data" {
  event_source_arn  = var.market_data_stream_arn
  function_name     = aws_lambda_alias.live["market-data-processor"].arn
  starting_position = "LATEST"

  # Batch configuration
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  parallelization_factor             = 10

  # Error handling
  maximum_retry_attempts                    = 3
  maximum_record_age_in_seconds             = 86400 # 24 hours
  bisect_batch_on_function_error            = true
  function_response_types                   = ["ReportBatchItemFailures"]

  # Destination for failed records
  destination_config {
    on_failure {
      destination_arn = var.market_data_dlq_arn
    }
  }

  tags = merge(local.lambda_tags, {
    Function = "market-data-processor"
    Source   = "kinesis"
  })
}

# =============================================================================
# EVENT SOURCE MAPPING: SQS FIFO -> WalletService
# Processes trade.executed events from trade-processing.fifo queue
# =============================================================================

resource "aws_lambda_event_source_mapping" "sqs_wallet_service" {
  event_source_arn = var.trade_processing_queue_arn
  function_name    = aws_lambda_alias.live["wallet-service-sqs"].arn

  # Batch configuration for FIFO ordering
  batch_size                         = 10
  maximum_batching_window_in_seconds = 0 # Process immediately for trade ordering

  # FIFO: ensure ordered processing per message group
  function_response_types = ["ReportBatchItemFailures"]

  # Scaling - limited for FIFO to maintain ordering
  scaling_config {
    maximum_concurrency = 5
  }

  tags = merge(local.lambda_tags, {
    Function = "wallet-service-sqs"
    Source   = "sqs-fifo"
  })
}

# =============================================================================
# EVENT SOURCE MAPPING: SQS DLQs -> DLQ Processor
# Processes messages from various dead-letter queues
# =============================================================================

resource "aws_lambda_event_source_mapping" "sqs_dlq_processor" {
  for_each = toset(var.dlq_source_arns)

  event_source_arn = each.value
  function_name    = aws_lambda_alias.live["dlq-processor"].arn

  batch_size                         = 5
  maximum_batching_window_in_seconds = 30

  function_response_types = ["ReportBatchItemFailures"]

  tags = merge(local.lambda_tags, {
    Function = "dlq-processor"
    Source   = "sqs-dlq"
  })
}

# =============================================================================
# EVENT SOURCE MAPPING: DynamoDB Streams -> Outbox Publisher
# Publishes domain events from OrderOutbox table to EventBridge
# =============================================================================

resource "aws_lambda_event_source_mapping" "dynamodb_outbox" {
  event_source_arn  = aws_dynamodb_table.order_outbox.stream_arn
  function_name     = aws_lambda_alias.live["outbox-publisher"].arn
  starting_position = "LATEST"

  # Batch configuration
  batch_size                         = 25
  maximum_batching_window_in_seconds = 5
  parallelization_factor             = 2

  # Error handling
  maximum_retry_attempts         = 5
  maximum_record_age_in_seconds  = 3600 # 1 hour
  bisect_batch_on_function_error = true
  function_response_types        = ["ReportBatchItemFailures"]

  # Destination for unprocessable records
  destination_config {
    on_failure {
      destination_arn = var.outbox_dlq_arn
    }
  }

  # Filter only INSERT and MODIFY events (new outbox entries)
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT", "MODIFY"]
      })
    }
  }

  tags = merge(local.lambda_tags, {
    Function = "outbox-publisher"
    Source   = "dynamodb-streams"
  })
}

# =============================================================================
# API GATEWAY INTEGRATIONS
# Note: API Gateway resources (api, routes, integrations, permissions) are 
# defined in api_gateway.tf (Task 6.6). The Lambda functions defined here
# expose their invoke ARNs via outputs for api_gateway.tf to reference.
# =============================================================================

# =============================================================================
# CLOUDWATCH LOG GROUPS
# Dedicated log groups with retention aligned to observability requirements
# =============================================================================

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.lambda_functions

  name              = "/aws/lambda/${var.name_prefix}-${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_internal_key_arn

  tags = merge(local.lambda_tags, {
    Function = each.key
  })
}

# =============================================================================
# VARIABLES
# =============================================================================

# Note: 'environment' and 'mandatory_tags' variables are defined in api_gateway.tf
# Note: 'log_retention_days' variable is defined in step_functions.tf

variable "name_prefix" {
  description = "Prefix for resource naming: {platform}-{environment}"
  type        = string
}

variable "lambda_package_version" {
  description = "Version tag for Lambda deployment package in S3"
  type        = string
  default     = "latest"
}

# --- Networking ---

variable "compute_subnet_ids" {
  description = "List of compute tier subnet IDs for Lambda VPC configuration"
  type        = list(string)
}

variable "compute_security_group_id" {
  description = "Security group ID for compute tier Lambda functions"
  type        = string
}

# --- S3 Buckets ---

variable "bronze_bucket_name" {
  description = "Name of the Bronze layer S3 bucket"
  type        = string
}

variable "silver_bucket_name" {
  description = "Name of the Silver layer S3 bucket"
  type        = string
}

variable "gold_bucket_name" {
  description = "Name of the Gold layer S3 bucket"
  type        = string
}

variable "regulatory_bucket_name" {
  description = "Name of the Regulatory Store S3 bucket"
  type        = string
}

# --- Streaming ---

variable "event_bus_name" {
  description = "Name of the EventBridge platform event bus"
  type        = string
}

variable "market_data_stream_arn" {
  description = "ARN of the Kinesis market data stream"
  type        = string
}

variable "trade_processing_queue_arn" {
  description = "ARN of the trade-processing SQS FIFO queue"
  type        = string
}

variable "market_data_dlq_arn" {
  description = "ARN of the market data dead-letter queue"
  type        = string
}

variable "market_data_dlq_url" {
  description = "URL of the market data dead-letter queue"
  type        = string
}

variable "dlq_source_arns" {
  description = "List of DLQ ARNs for the DLQ processor to consume"
  type        = list(string)
  default     = []
}

variable "outbox_dlq_arn" {
  description = "ARN of the DLQ for outbox publisher failures"
  type        = string
}

# --- IAM Roles ---

variable "market_data_lambda_role_arn" {
  description = "ARN of the Market Data Lambda execution role"
  type        = string
}

variable "order_manager_role_arn" {
  description = "ARN of the Order Manager Lambda execution role"
  type        = string
}

variable "wallet_service_role_arn" {
  description = "ARN of the Wallet Service Lambda execution role"
  type        = string
}

variable "advisory_agent_role_arn" {
  description = "ARN of the Advisory Agent Lambda execution role"
  type        = string
}

variable "dlq_processor_role_arn" {
  description = "ARN of the DLQ Processor Lambda execution role"
  type        = string
}

variable "outbox_publisher_role_arn" {
  description = "ARN of the Outbox Publisher Lambda execution role"
  type        = string
}

# --- API Gateway ---
# Note: API Gateway resources and variables are in api_gateway.tf.
# Lambda outputs (invoke ARNs) are consumed by api_gateway.tf variables.

# --- KMS ---

variable "kms_internal_key_arn" {
  description = "KMS key ARN for Internal data classification (logs)"
  type        = string
}

# --- Data Catalog ---

variable "bronze_database_name" {
  description = "Glue Data Catalog database name for Bronze layer"
  type        = string
}

# --- SageMaker ---

variable "sagemaker_endpoint_name" {
  description = "Name of the SageMaker inference endpoint for Advisory Agent"
  type        = string
  default     = "vb-advisory-endpoint"
}

# --- Observability ---
# Note: log_retention_days variable is defined in step_functions.tf

# --- DLQ ARN Map (per-function) ---

variable "function_dlq_arns" {
  description = "Map of function name to its dedicated DLQ ARN for dead-letter configuration"
  type        = map(string)
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "lambda_function_arns" {
  description = "Map of function name to Lambda function ARN"
  value = {
    for key, fn in aws_lambda_function.functions :
    key => fn.arn
  }
}

output "lambda_function_names" {
  description = "Map of function name to Lambda function name"
  value = {
    for key, fn in aws_lambda_function.functions :
    key => fn.function_name
  }
}

output "lambda_function_invoke_arns" {
  description = "Map of function name to Lambda invoke ARN"
  value = {
    for key, fn in aws_lambda_function.functions :
    key => fn.invoke_arn
  }
}

output "lambda_alias_arns" {
  description = "Map of function name to live alias ARN"
  value = {
    for key, alias in aws_lambda_alias.live :
    key => alias.arn
  }
}

output "lambda_alias_invoke_arns" {
  description = "Map of function name to live alias invoke ARN"
  value = {
    for key, alias in aws_lambda_alias.live :
    key => alias.invoke_arn
  }
}

output "idempotency_table_name" {
  description = "Name of the IdempotencyStore DynamoDB table"
  value       = aws_dynamodb_table.idempotency_store.name
}

output "circuit_breaker_table_name" {
  description = "Name of the CircuitBreakerState DynamoDB table"
  value       = aws_dynamodb_table.circuit_breaker_state.name
}

output "orders_table_name" {
  description = "Name of the Orders DynamoDB table"
  value       = aws_dynamodb_table.orders.name
}

output "order_outbox_table_name" {
  description = "Name of the OrderOutbox DynamoDB table"
  value       = aws_dynamodb_table.order_outbox.name
}

output "order_outbox_stream_arn" {
  description = "ARN of the OrderOutbox DynamoDB stream"
  value       = aws_dynamodb_table.order_outbox.stream_arn
}

output "portfolio_table_name" {
  description = "Name of the Portfolio DynamoDB table"
  value       = aws_dynamodb_table.portfolio.name
}
