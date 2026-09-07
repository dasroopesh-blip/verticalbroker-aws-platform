# ===========================================================================
# Reranker module: an Amazon SageMaker real-time endpoint hosting a
# cross-encoder reranker (Stage 2 of the ranking funnel).
#
# LEARNING NOTE: SageMaker serves a custom model behind an HTTPS endpoint. Here
# it hosts a cross-encoder that re-scores the (query, passage) shortlist for
# precision that vector similarity alone can't reach. This is *the* reason
# SageMaker belongs in this architecture — Bedrock covers embeddings/reasoning,
# OpenSearch covers retrieval, SageMaker covers custom ranking ML.
#
# The endpoint is shared safely across tenants: it only ever sees the shortlist
# passed to it (already tenant-filtered) and keeps no state between calls.
#
# COST TIP: a real-time endpoint bills per hour while "InService". For dev, use
# the smallest instance and `terraform destroy` (or scale to a Serverless
# Inference config) when idle. Reranking can also be disabled entirely
# (FA_ENABLE_RERANKING=false) to fall back to the fused ranking with no endpoint.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "model_data_url" {
  description = "S3 URI of the packaged reranker model artifact (model.tar.gz)."
  type        = string
}

variable "image_uri" {
  description = "ECR image URI for the SageMaker inference container (e.g. HF PyTorch inference DLC)."
  type        = string
}

variable "execution_role_arn" {
  description = "IAM role SageMaker assumes to pull the model + image."
  type        = string
}

variable "instance_type" {
  description = "Endpoint instance type. ml.t2.medium/ml.m5.large are cheap dev options."
  type        = string
  default     = "ml.m5.large"
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "kms_key_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# The model: points SageMaker at the container image + model artifact.
resource "aws_sagemaker_model" "reranker" {
  name               = "${var.name_prefix}-reranker"
  execution_role_arn = var.execution_role_arn

  primary_container {
    image          = var.image_uri
    model_data_url = var.model_data_url
    environment = {
      # Task hint for HF inference containers hosting a cross-encoder.
      HF_TASK = "text-classification"
    }
  }

  tags = var.tags
}

# Endpoint configuration: instance sizing + which model variant to serve.
resource "aws_sagemaker_endpoint_configuration" "reranker" {
  name        = "${var.name_prefix}-reranker-config"
  kms_key_arn = var.kms_key_arn

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.reranker.name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
    initial_variant_weight = 1.0
  }

  tags = var.tags
}

# The live HTTPS endpoint the app invokes (FA_SAGEMAKER_RERANKER_ENDPOINT).
resource "aws_sagemaker_endpoint" "reranker" {
  name                 = "${var.name_prefix}-reranker"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.reranker.name
  tags                 = var.tags
}

output "endpoint_name" {
  description = "SageMaker endpoint name — set as FA_SAGEMAKER_RERANKER_ENDPOINT."
  value       = aws_sagemaker_endpoint.reranker.name
}

output "model_name" {
  value = aws_sagemaker_model.reranker.name
}
