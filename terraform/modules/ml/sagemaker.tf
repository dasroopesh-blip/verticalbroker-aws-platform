# SageMaker Infrastructure - VerticalBroker AWS Data Engineering Platform
#
# Defines SageMaker Domain, Model Package Group, real-time inference endpoint
# with A/B testing variants, auto-scaling, and Model Monitor.
#
# Requirements:
#   12.3 - SageMaker Model Registry with versioning and metadata
#   12.4 - Real-time inference endpoint (<500ms latency)
#   12.7 - A/B testing with configurable traffic splitting
#   13.5 - Mandatory tags on all resources

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# =============================================================================
# LOCAL VALUES
# =============================================================================

locals {
  ml_tags = merge(var.mandatory_tags, {
    Module  = "ml"
    Service = "sagemaker"
  })

  endpoint_name    = "${var.name_prefix}-${var.endpoint_name}"
  domain_name      = "${var.name_prefix}-${var.sagemaker_domain_name}"
  monitor_role_arn = var.model_monitor_role_arn != "" ? var.model_monitor_role_arn : var.sagemaker_execution_role_arn
}

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# SAGEMAKER DOMAIN
# Requirement 12.2: SageMaker training environment
# =============================================================================

resource "aws_sagemaker_domain" "ml_domain" {
  domain_name = local.domain_name
  auth_mode   = var.sagemaker_auth_mode

  default_user_settings {
    execution_role = var.sagemaker_execution_role_arn

    security_groups = var.security_group_ids

    sharing_settings {
      notebook_output_option = "Disabled"
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  default_space_settings {
    execution_role = var.sagemaker_execution_role_arn

    security_groups = var.security_group_ids
  }

  retention_policy {
    home_efs_file_system = "Delete"
  }

  tags = merge(local.ml_tags, {
    Name = local.domain_name
  })
}

# =============================================================================
# MODEL PACKAGE GROUP (Model Registry)
# Requirement 12.3: Version all trained models with metadata
# =============================================================================

resource "aws_sagemaker_model_package_group" "advisory_models" {
  model_package_group_name        = var.model_package_group_name
  model_package_group_description = var.model_package_group_description

  tags = merge(local.ml_tags, {
    Name = var.model_package_group_name
  })
}

# =============================================================================
# SAGEMAKER MODEL
# Placeholder model resource for endpoint configuration
# =============================================================================

resource "aws_sagemaker_model" "advisory_production" {
  name               = "${local.endpoint_name}-production"
  execution_role_arn = var.sagemaker_execution_role_arn

  primary_container {
    image          = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-advisory-inference:latest"
    model_data_url = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/advisory/production/model.tar.gz"
    environment = {
      SAGEMAKER_PROGRAM  = "inference.py"
      MODEL_VERSION      = "production"
      ENVIRONMENT        = var.environment
    }
  }

  vpc_config {
    subnets            = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  tags = merge(local.ml_tags, {
    Name         = "${local.endpoint_name}-production"
    ModelVariant = "production"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_sagemaker_model" "advisory_canary" {
  name               = "${local.endpoint_name}-canary"
  execution_role_arn = var.sagemaker_execution_role_arn

  primary_container {
    image          = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-advisory-inference:latest"
    model_data_url = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/advisory/canary/model.tar.gz"
    environment = {
      SAGEMAKER_PROGRAM  = "inference.py"
      MODEL_VERSION      = "canary"
      ENVIRONMENT        = var.environment
    }
  }

  vpc_config {
    subnets            = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  tags = merge(local.ml_tags, {
    Name         = "${local.endpoint_name}-canary"
    ModelVariant = "canary"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# ENDPOINT CONFIGURATION WITH A/B TESTING
# Requirement 12.7: A/B testing with configurable traffic splitting
# Requirement 12.4: Real-time inference endpoint (<500ms)
# =============================================================================

resource "aws_sagemaker_endpoint_configuration" "advisory" {
  name = "${local.endpoint_name}-config"

  # Production variant: receives majority of traffic (90%)
  production_variants {
    variant_name           = "production"
    model_name             = aws_sagemaker_model.advisory_production.name
    initial_instance_count = var.production_variant_instance_count
    instance_type          = var.production_variant_instance_type
    initial_variant_weight = var.production_variant_weight
  }

  # Canary variant: receives minority of traffic (10%) for A/B testing
  production_variants {
    variant_name           = "canary"
    model_name             = aws_sagemaker_model.advisory_canary.name
    initial_instance_count = var.canary_variant_instance_count
    instance_type          = var.canary_variant_instance_type
    initial_variant_weight = var.canary_variant_weight
  }

  kms_key_arn = var.kms_key_arn

  data_capture_config {
    enable_capture              = true
    initial_sampling_percentage = 100
    destination_s3_uri          = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/endpoint-data-capture"

    capture_options {
      capture_mode = "Input"
    }
    capture_options {
      capture_mode = "Output"
    }

    capture_content_type_header {
      json_content_types = ["application/json"]
    }
  }

  tags = merge(local.ml_tags, {
    Name = "${local.endpoint_name}-config"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# SAGEMAKER ENDPOINT
# Requirement 12.4: Real-time inference endpoint
# =============================================================================

resource "aws_sagemaker_endpoint" "advisory" {
  name                 = local.endpoint_name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.advisory.name

  tags = merge(local.ml_tags, {
    Name = local.endpoint_name
  })
}

# =============================================================================
# ENDPOINT AUTO-SCALING
# Auto-scale inference instances based on InvocationsPerInstance
# Min: 1, Max: 10, target tracking on InvocationsPerInstance
# =============================================================================

resource "aws_appautoscaling_target" "sagemaker_production" {
  max_capacity       = var.autoscaling_max_capacity
  min_capacity       = var.autoscaling_min_capacity
  resource_id        = "endpoint/${aws_sagemaker_endpoint.advisory.name}/variant/production"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_policy" "sagemaker_production_scaling" {
  name               = "${local.endpoint_name}-production-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sagemaker_production.resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_production.scalable_dimension
  service_namespace  = aws_appautoscaling_target.sagemaker_production.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    target_value       = var.autoscaling_target_invocations
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

resource "aws_appautoscaling_target" "sagemaker_canary" {
  max_capacity       = 3
  min_capacity       = var.autoscaling_min_capacity
  resource_id        = "endpoint/${aws_sagemaker_endpoint.advisory.name}/variant/canary"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_policy" "sagemaker_canary_scaling" {
  name               = "${local.endpoint_name}-canary-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sagemaker_canary.resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_canary.scalable_dimension
  service_namespace  = aws_appautoscaling_target.sagemaker_canary.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    target_value       = var.autoscaling_target_invocations
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

# =============================================================================
# MODEL MONITOR - DATA QUALITY
# Requirement 12.3: Monitor data drift and model quality
# =============================================================================

resource "aws_sagemaker_data_quality_job_definition" "advisory" {
  count = var.enable_model_monitor ? 1 : 0

  name     = "${local.endpoint_name}-data-quality"
  role_arn = local.monitor_role_arn

  data_quality_app_specification {
    image_uri = "156813124566.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/sagemaker-model-monitor-analyzer"
  }

  data_quality_job_input {
    endpoint_input {
      endpoint_name          = aws_sagemaker_endpoint.advisory.name
      local_path             = "/opt/ml/processing/input"
      s3_input_mode          = "File"
      s3_data_distribution_type = "FullyReplicated"
    }
  }

  data_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri        = var.monitor_output_s3_uri != "" ? "${var.monitor_output_s3_uri}/data-quality" : "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/data-quality"
        local_path    = "/opt/ml/processing/output"
        s3_upload_mode = "EndOfJob"
      }
    }
    kms_key_id = var.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.monitor_instance_type
      volume_size_in_gb = 50
      volume_kms_key_id = var.kms_key_arn
    }
  }

  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false

    vpc_config {
      subnets            = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  stopping_condition {
    max_runtime_in_seconds = 3600
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-data-quality"
    MonitorType = "DataQuality"
  })
}

# =============================================================================
# MODEL MONITOR - MODEL QUALITY
# =============================================================================

resource "aws_sagemaker_model_quality_job_definition" "advisory" {
  count = var.enable_model_monitor ? 1 : 0

  name     = "${local.endpoint_name}-model-quality"
  role_arn = local.monitor_role_arn

  model_quality_app_specification {
    image_uri    = "156813124566.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/sagemaker-model-monitor-analyzer"
    problem_type = "Regression"
  }

  model_quality_job_input {
    endpoint_input {
      endpoint_name          = aws_sagemaker_endpoint.advisory.name
      local_path             = "/opt/ml/processing/input"
      s3_input_mode          = "File"
      s3_data_distribution_type = "FullyReplicated"
      inference_attribute    = "0"
    }

    ground_truth_s3_input {
      s3_uri = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/ground-truth/"
    }
  }

  model_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri        = var.monitor_output_s3_uri != "" ? "${var.monitor_output_s3_uri}/model-quality" : "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/model-quality"
        local_path    = "/opt/ml/processing/output"
        s3_upload_mode = "EndOfJob"
      }
    }
    kms_key_id = var.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.monitor_instance_type
      volume_size_in_gb = 50
      volume_kms_key_id = var.kms_key_arn
    }
  }

  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false

    vpc_config {
      subnets            = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  stopping_condition {
    max_runtime_in_seconds = 3600
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-model-quality"
    MonitorType = "ModelQuality"
  })
}

# =============================================================================
# MODEL MONITOR - BIAS
# Requirement 12.8: Bias detection across demographic groups
# =============================================================================

resource "aws_sagemaker_model_bias_job_definition" "advisory" {
  count = var.enable_model_monitor ? 1 : 0

  name     = "${local.endpoint_name}-bias"
  role_arn = local.monitor_role_arn

  model_bias_app_specification {
    image_uri  = "205585389593.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/sagemaker-clarify-processing:1.0"
    config_uri = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/bias/analysis_config.json"
  }

  model_bias_job_input {
    endpoint_input {
      endpoint_name          = aws_sagemaker_endpoint.advisory.name
      local_path             = "/opt/ml/processing/input"
      s3_input_mode          = "File"
      s3_data_distribution_type = "FullyReplicated"
      inference_attribute    = "0"
      features_attribute     = ""
    }

    ground_truth_s3_input {
      s3_uri = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/ground-truth/"
    }
  }

  model_bias_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri        = var.monitor_output_s3_uri != "" ? "${var.monitor_output_s3_uri}/bias" : "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/bias"
        local_path    = "/opt/ml/processing/output"
        s3_upload_mode = "EndOfJob"
      }
    }
    kms_key_id = var.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.monitor_instance_type
      volume_size_in_gb = 50
      volume_kms_key_id = var.kms_key_arn
    }
  }

  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false

    vpc_config {
      subnets            = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  stopping_condition {
    max_runtime_in_seconds = 3600
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-bias"
    MonitorType = "Bias"
  })
}

# =============================================================================
# MODEL MONITOR - EXPLAINABILITY
# Requirement 12.8: Explainability reports (SHAP-based)
# =============================================================================

resource "aws_sagemaker_model_explainability_job_definition" "advisory" {
  count = var.enable_model_monitor ? 1 : 0

  name     = "${local.endpoint_name}-explainability"
  role_arn = local.monitor_role_arn

  model_explainability_app_specification {
    image_uri  = "205585389593.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/sagemaker-clarify-processing:1.0"
    config_uri = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/explainability/analysis_config.json"
  }

  model_explainability_job_input {
    endpoint_input {
      endpoint_name          = aws_sagemaker_endpoint.advisory.name
      local_path             = "/opt/ml/processing/input"
      s3_input_mode          = "File"
      s3_data_distribution_type = "FullyReplicated"
      inference_attribute    = "0"
      features_attribute     = ""
    }
  }

  model_explainability_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri        = var.monitor_output_s3_uri != "" ? "${var.monitor_output_s3_uri}/explainability" : "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/monitor/explainability"
        local_path    = "/opt/ml/processing/output"
        s3_upload_mode = "EndOfJob"
      }
    }
    kms_key_id = var.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.monitor_instance_type
      volume_size_in_gb = 50
      volume_kms_key_id = var.kms_key_arn
    }
  }

  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false

    vpc_config {
      subnets            = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  stopping_condition {
    max_runtime_in_seconds = 3600
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-explainability"
    MonitorType = "Explainability"
  })
}

# =============================================================================
# MODEL MONITOR SCHEDULES
# =============================================================================

resource "aws_sagemaker_monitoring_schedule" "data_quality" {
  count = var.enable_model_monitor ? 1 : 0

  name = "${local.endpoint_name}-data-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_data_quality_job_definition.advisory[0].name
    monitoring_type                = "DataQuality"

    schedule_config {
      schedule_expression = var.monitor_schedule_expression
    }
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-data-quality-schedule"
    MonitorType = "DataQuality"
  })

  depends_on = [aws_sagemaker_endpoint.advisory]
}

resource "aws_sagemaker_monitoring_schedule" "model_quality" {
  count = var.enable_model_monitor ? 1 : 0

  name = "${local.endpoint_name}-model-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_model_quality_job_definition.advisory[0].name
    monitoring_type                = "ModelQuality"

    schedule_config {
      schedule_expression = var.monitor_schedule_expression
    }
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-model-quality-schedule"
    MonitorType = "ModelQuality"
  })

  depends_on = [aws_sagemaker_endpoint.advisory]
}

resource "aws_sagemaker_monitoring_schedule" "bias" {
  count = var.enable_model_monitor ? 1 : 0

  name = "${local.endpoint_name}-bias-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_model_bias_job_definition.advisory[0].name
    monitoring_type                = "ModelBias"

    schedule_config {
      schedule_expression = var.monitor_schedule_expression
    }
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-bias-schedule"
    MonitorType = "Bias"
  })

  depends_on = [aws_sagemaker_endpoint.advisory]
}

resource "aws_sagemaker_monitoring_schedule" "explainability" {
  count = var.enable_model_monitor ? 1 : 0

  name = "${local.endpoint_name}-explainability-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_model_explainability_job_definition.advisory[0].name
    monitoring_type                = "ModelExplainability"

    schedule_config {
      schedule_expression = var.monitor_schedule_expression
    }
  }

  tags = merge(local.ml_tags, {
    Name        = "${local.endpoint_name}-explainability-schedule"
    MonitorType = "Explainability"
  })

  depends_on = [aws_sagemaker_endpoint.advisory]
}
