# Lambda Layers for shared dependencies across all VerticalBroker Lambda functions.
#
# Packages: aws-lambda-powertools, boto3, pydantic
# Compatible runtimes: python3.12
# Version retention: keep last 3 versions
#
# Requirements: 7.3 - Lambda Layers for shared dependencies including
#              AWS SDK extensions, data validation schemas, and common utilities

# -----------------------------------------------------------------------------
# Lambda Layer: Shared Dependencies
# Includes aws-lambda-powertools, boto3 (latest), and pydantic for validation
# -----------------------------------------------------------------------------

resource "aws_lambda_layer_version" "shared_dependencies" {
  layer_name          = "${var.project_prefix}-shared-dependencies"
  description         = "Shared Python dependencies: aws-lambda-powertools, boto3, pydantic"
  compatible_runtimes = ["python3.12"]
  s3_bucket           = var.artifacts_bucket_name
  s3_key              = "lambda-layers/shared-dependencies/${var.layer_version}/python.zip"

  lifecycle {
    create_before_destroy = true
  }
}

# Retain last 3 versions of the shared dependencies layer
resource "aws_lambda_layer_version" "shared_dependencies_retention" {
  count = var.retain_previous_layer_versions ? 1 : 0

  layer_name          = "${var.project_prefix}-shared-dependencies-prev"
  description         = "Previous version of shared dependencies layer (retention)"
  compatible_runtimes = ["python3.12"]
  s3_bucket           = var.artifacts_bucket_name
  s3_key              = "lambda-layers/shared-dependencies/${var.previous_layer_version}/python.zip"

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Lambda Layer: Common Utilities
# Platform-specific utilities: idempotency, circuit breaker, retry, outbox
# -----------------------------------------------------------------------------

resource "aws_lambda_layer_version" "common_utilities" {
  layer_name          = "${var.project_prefix}-common-utilities"
  description         = "Platform utilities: idempotency, circuit_breaker, retry, dlq_handler, outbox"
  compatible_runtimes = ["python3.12"]
  s3_bucket           = var.artifacts_bucket_name
  s3_key              = "lambda-layers/common-utilities/${var.layer_version}/python.zip"

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Lambda Layer: Data Models
# Shared data models: market_data, trade, events
# -----------------------------------------------------------------------------

resource "aws_lambda_layer_version" "data_models" {
  layer_name          = "${var.project_prefix}-data-models"
  description         = "Shared data models: market_data, trade, events"
  compatible_runtimes = ["python3.12"]
  s3_bucket           = var.artifacts_bucket_name
  s3_key              = "lambda-layers/data-models/${var.layer_version}/python.zip"

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Layer version cleanup - Lambda Layer version retention policy
# Keeps the last 3 versions by using a null_resource with triggers
# -----------------------------------------------------------------------------

resource "null_resource" "layer_version_cleanup" {
  triggers = {
    shared_deps_version   = aws_lambda_layer_version.shared_dependencies.version
    common_utils_version  = aws_lambda_layer_version.common_utilities.version
    data_models_version   = aws_lambda_layer_version.data_models.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Retain last 3 versions of each layer, delete older ones
      for LAYER_NAME in "${var.project_prefix}-shared-dependencies" \
                        "${var.project_prefix}-common-utilities" \
                        "${var.project_prefix}-data-models"; do
        VERSIONS=$(aws lambda list-layer-versions \
          --layer-name "$LAYER_NAME" \
          --query 'LayerVersions[3:].Version' \
          --output text \
          --region ${var.aws_region} 2>/dev/null || true)
        
        for VERSION in $VERSIONS; do
          aws lambda delete-layer-version \
            --layer-name "$LAYER_NAME" \
            --version-number "$VERSION" \
            --region ${var.aws_region} 2>/dev/null || true
        done
      done
    EOT
  }
}

# -----------------------------------------------------------------------------
# Variables for Lambda Layers
# -----------------------------------------------------------------------------

variable "project_prefix" {
  description = "Project prefix for resource naming"
  type        = string
  default     = "verticalbroker"
}

variable "artifacts_bucket_name" {
  description = "S3 bucket storing Lambda layer deployment artifacts"
  type        = string
}

variable "layer_version" {
  description = "Current version tag for Lambda layer packages"
  type        = string
  default     = "latest"
}

variable "previous_layer_version" {
  description = "Previous version tag for retention purposes"
  type        = string
  default     = ""
}

variable "retain_previous_layer_versions" {
  description = "Whether to retain previous layer versions"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "AWS region for Lambda layer deployment"
  type        = string
  default     = "us-east-1"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "shared_dependencies_layer_arn" {
  description = "ARN of the shared dependencies Lambda layer (latest version)"
  value       = aws_lambda_layer_version.shared_dependencies.arn
}

output "common_utilities_layer_arn" {
  description = "ARN of the common utilities Lambda layer (latest version)"
  value       = aws_lambda_layer_version.common_utilities.arn
}

output "data_models_layer_arn" {
  description = "ARN of the data models Lambda layer (latest version)"
  value       = aws_lambda_layer_version.data_models.arn
}

output "all_layer_arns" {
  description = "List of all Lambda layer ARNs for attachment to functions"
  value = [
    aws_lambda_layer_version.shared_dependencies.arn,
    aws_lambda_layer_version.common_utilities.arn,
    aws_lambda_layer_version.data_models.arn,
  ]
}

# -----------------------------------------------------------------------------
# Tags (applied via default_tags in provider, but documented here)
# Mandatory tags: Environment, Service, Owner, CostCenter, 
#                 DataClassification, Compliance
# -----------------------------------------------------------------------------
