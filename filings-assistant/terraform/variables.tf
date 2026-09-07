# ---------------------------------------------------------------------------
# Root input variables.
#
# LEARNING NOTE: variables are the inputs to your Terraform "program". Values
# come from a *.tfvars file (see environments/dev.tfvars) or the CLI. Every
# variable declares a type and description (a project convention + good habit).
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project name, used to prefix and tag resources."
  type        = string
  default     = "filings-assistant"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into. Bedrock model availability varies by region."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "opensearch_instance_type" {
  description = "OpenSearch data node instance type. t3.small.search is the cheapest for dev."
  type        = string
  default     = "t3.small.search"
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch data nodes. 1 for dev; 3 for prod HA."
  type        = number
  default     = 1
}

variable "db_instance_class" {
  description = "RDS Postgres instance class. db.t3.micro is cheapest for dev."
  type        = string
  default     = "db.t3.micro"
}

variable "bedrock_reasoning_model_id" {
  description = "Bedrock model ID for the agent's reasoning (Claude Sonnet)."
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "bedrock_embedding_model_id" {
  description = "Bedrock model ID for embeddings (Titan Text Embeddings V2)."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget (USD). Alerts fire at 50% and 90% of this."
  type        = number
  default     = 150
}

variable "enable_reranker" {
  description = "Whether to deploy the SageMaker cross-encoder reranker endpoint. Requires reranker_model_data_url + reranker_image_uri. Off by default so plan/apply works before a model is packaged (app falls back to fused ranking / local reranker)."
  type        = bool
  default     = false
}

variable "reranker_model_data_url" {
  description = "S3 URI of the packaged reranker model artifact (model.tar.gz). Required when enable_reranker=true."
  type        = string
  default     = ""
}

variable "reranker_image_uri" {
  description = "ECR image URI for the SageMaker inference container. Required when enable_reranker=true."
  type        = string
  default     = ""
}

variable "reranker_instance_type" {
  description = "SageMaker reranker endpoint instance type."
  type        = string
  default     = "ml.m5.large"
}

variable "budget_alert_email" {
  description = "Email address to receive budget + monitoring alerts."
  type        = string
  default     = "you@example.com"
}
