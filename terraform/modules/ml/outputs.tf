# ML Module Outputs - VerticalBroker AWS Data Engineering Platform
#
# Exposes key resource identifiers and ARNs for cross-module reference.
#
# Requirements: 12.3, 12.4, 12.7

# =============================================================================
# SAGEMAKER DOMAIN
# =============================================================================

output "sagemaker_domain_id" {
  description = "SageMaker Domain ID"
  value       = aws_sagemaker_domain.ml_domain.id
}

output "sagemaker_domain_arn" {
  description = "SageMaker Domain ARN"
  value       = aws_sagemaker_domain.ml_domain.arn
}

output "sagemaker_domain_url" {
  description = "SageMaker Domain URL for Studio access"
  value       = aws_sagemaker_domain.ml_domain.url
}

# =============================================================================
# MODEL REGISTRY
# =============================================================================

output "model_package_group_name" {
  description = "Model Package Group name for advisory models"
  value       = aws_sagemaker_model_package_group.advisory_models.model_package_group_name
}

output "model_package_group_arn" {
  description = "Model Package Group ARN"
  value       = aws_sagemaker_model_package_group.advisory_models.arn
}

# =============================================================================
# ENDPOINT
# =============================================================================

output "endpoint_name" {
  description = "SageMaker real-time inference endpoint name"
  value       = aws_sagemaker_endpoint.advisory.name
}

output "endpoint_arn" {
  description = "SageMaker endpoint ARN"
  value       = aws_sagemaker_endpoint.advisory.arn
}

output "endpoint_configuration_name" {
  description = "Endpoint configuration name (for reference in Lambda env vars)"
  value       = aws_sagemaker_endpoint_configuration.advisory.name
}

# =============================================================================
# PIPELINE
# =============================================================================

output "pipeline_name" {
  description = "SageMaker Pipeline name for advisory model training"
  value       = aws_sagemaker_pipeline.advisory_training.pipeline_name
}

output "pipeline_arn" {
  description = "SageMaker Pipeline ARN"
  value       = aws_sagemaker_pipeline.advisory_training.arn
}

# =============================================================================
# AUTO-SCALING
# =============================================================================

output "autoscaling_target_production_resource_id" {
  description = "Auto-scaling target resource ID for the production variant"
  value       = aws_appautoscaling_target.sagemaker_production.resource_id
}

output "autoscaling_target_canary_resource_id" {
  description = "Auto-scaling target resource ID for the canary variant"
  value       = aws_appautoscaling_target.sagemaker_canary.resource_id
}

# =============================================================================
# MODEL MONITOR
# =============================================================================

output "data_quality_monitor_name" {
  description = "Data quality monitoring job definition name"
  value       = var.enable_model_monitor ? aws_sagemaker_data_quality_job_definition.advisory[0].name : ""
}

output "model_quality_monitor_name" {
  description = "Model quality monitoring job definition name"
  value       = var.enable_model_monitor ? aws_sagemaker_model_quality_job_definition.advisory[0].name : ""
}

output "bias_monitor_name" {
  description = "Bias monitoring job definition name"
  value       = var.enable_model_monitor ? aws_sagemaker_model_bias_job_definition.advisory[0].name : ""
}

output "explainability_monitor_name" {
  description = "Explainability monitoring job definition name"
  value       = var.enable_model_monitor ? aws_sagemaker_model_explainability_job_definition.advisory[0].name : ""
}

# =============================================================================
# MODELS
# =============================================================================

output "production_model_name" {
  description = "Name of the production SageMaker model"
  value       = aws_sagemaker_model.advisory_production.name
}

output "canary_model_name" {
  description = "Name of the canary SageMaker model"
  value       = aws_sagemaker_model.advisory_canary.name
}
