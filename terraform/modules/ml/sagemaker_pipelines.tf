# SageMaker Pipelines - VerticalBroker AWS Data Engineering Platform
#
# Defines the SageMaker Pipeline for RL advisory model training with 4 steps:
#   1. FeatureEngineering - Processing job extracting features from Gold Layer
#   2. Training           - RLEstimator with PPO on ml.p3.2xlarge
#   3. Evaluation         - Processing job for performance, bias, fairness metrics
#   4. Registration       - Model registration with approval workflow
#
# Requirements:
#   12.2 - SageMaker RL training on Gold Layer historical data
#   12.3 - Model versioning with metadata (dataset version, hyperparameters, metrics, approval)
#   12.8 - Model governance review (bias, fairness, explainability) before deployment
#   13.5 - Mandatory tags on all resources

# =============================================================================
# LOCAL VALUES
# =============================================================================

locals {
  pipeline_name = "${var.name_prefix}-${var.pipeline_name}"

  # Training hyperparameters for PPO RL algorithm
  training_hyperparameters = {
    algorithm     = "PPO"
    learning_rate = "0.0003"
    gamma         = "0.99"
    num_episodes  = "10000"
    batch_size    = "256"
    framework     = "ray"
  }

  # S3 paths for pipeline artifacts
  pipeline_s3_prefix = "s3://${var.model_artifacts_bucket_name}/${var.name_prefix}/pipeline"
  training_data_uri  = "s3://${var.gold_layer_bucket_name}/${var.name_prefix}/training-data"
}

# =============================================================================
# SAGEMAKER PIPELINE DEFINITION
# Requirement 12.2: End-to-end training pipeline
# =============================================================================

resource "aws_sagemaker_pipeline" "advisory_training" {
  pipeline_name         = local.pipeline_name
  pipeline_display_name = "VerticalBroker Advisory Model Training"
  role_arn              = var.sagemaker_execution_role_arn

  pipeline_definition = jsonencode({
    Version = "2020-12-01"
    Metadata = {
      Description = "RL training pipeline for advisory agent: Feature Engineering → Training → Evaluation → Registration"
      Tags        = var.mandatory_tags
    }
    Parameters = [
      {
        Name         = "TrainingDataUri"
        Type         = "String"
        DefaultValue = local.training_data_uri
      },
      {
        Name         = "ModelApprovalStatus"
        Type         = "String"
        DefaultValue = "PendingManualApproval"
      },
      {
        Name         = "DatasetVersion"
        Type         = "String"
        DefaultValue = "latest"
      },
      {
        Name         = "ProcessingInstanceType"
        Type         = "String"
        DefaultValue = var.feature_engineering_instance_type
      },
      {
        Name         = "TrainingInstanceType"
        Type         = "String"
        DefaultValue = var.training_instance_type
      }
    ]
    Steps = [
      # Step 1: Feature Engineering
      {
        Name = "FeatureEngineering"
        Type = "Processing"
        Arguments = {
          ProcessingResources = {
            ClusterConfig = {
              InstanceCount = var.feature_engineering_instance_count
              InstanceType  = { "Get" = "Parameters.ProcessingInstanceType" }
              VolumeSizeInGB = 50
              VolumeKmsKeyId = var.kms_key_arn
            }
          }
          AppSpecification = {
            ImageUri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-feature-engineering:latest"
            ContainerArguments = [
              "--gold-layer-uri", { "Get" = "Parameters.TrainingDataUri" },
              "--output-uri", "${local.pipeline_s3_prefix}/features/",
              "--dataset-version", { "Get" = "Parameters.DatasetVersion" }
            ]
          }
          ProcessingInputs = [
            {
              InputName = "gold-layer-data"
              S3Input = {
                S3Uri          = { "Get" = "Parameters.TrainingDataUri" }
                LocalPath      = "/opt/ml/processing/input"
                S3DataType     = "S3Prefix"
                S3InputMode    = "File"
                S3CompressionType = "None"
              }
            }
          ]
          ProcessingOutputConfig = {
            Outputs = [
              {
                OutputName = "features"
                S3Output = {
                  S3Uri        = "${local.pipeline_s3_prefix}/features/"
                  LocalPath    = "/opt/ml/processing/output/features"
                  S3UploadMode = "EndOfJob"
                }
              },
              {
                OutputName = "train-test-split"
                S3Output = {
                  S3Uri        = "${local.pipeline_s3_prefix}/train-test-split/"
                  LocalPath    = "/opt/ml/processing/output/split"
                  S3UploadMode = "EndOfJob"
                }
              }
            ]
            KmsKeyId = var.kms_key_arn
          }
          RoleArn = var.sagemaker_execution_role_arn
          NetworkConfig = {
            EnableInterContainerTrafficEncryption = true
            EnableNetworkIsolation                = false
            VpcConfig = {
              Subnets        = var.subnet_ids
              SecurityGroupIds = var.security_group_ids
            }
          }
          StoppingCondition = {
            MaxRuntimeInSeconds = 7200
          }
          Tags = [for k, v in var.mandatory_tags : { Key = k, Value = v }]
        }
      },
      # Step 2: Training (RLEstimator with PPO)
      {
        Name = "Training"
        Type = "Training"
        Arguments = {
          AlgorithmSpecification = {
            TrainingImage   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-rl-training:latest"
            TrainingInputMode = "File"
          }
          HyperParameters = local.training_hyperparameters
          InputDataConfig = [
            {
              ChannelName = "train"
              DataSource = {
                S3DataSource = {
                  S3DataType        = "S3Prefix"
                  S3Uri             = "${local.pipeline_s3_prefix}/features/"
                  S3DataDistributionType = "FullyReplicated"
                }
              }
              ContentType = "application/x-parquet"
            }
          ]
          OutputDataConfig = {
            S3OutputPath = "${local.pipeline_s3_prefix}/model-artifacts/"
            KmsKeyId     = var.kms_key_arn
          }
          ResourceConfig = {
            InstanceCount  = var.training_instance_count
            InstanceType   = { "Get" = "Parameters.TrainingInstanceType" }
            VolumeSizeInGB = 100
            VolumeKmsKeyId = var.kms_key_arn
          }
          RoleArn = var.sagemaker_execution_role_arn
          StoppingCondition = {
            MaxRuntimeInSeconds = var.training_max_runtime_seconds
          }
          VpcConfig = {
            Subnets        = var.subnet_ids
            SecurityGroupIds = var.security_group_ids
          }
          Tags = [for k, v in var.mandatory_tags : { Key = k, Value = v }]
        }
      },
      # Step 3: Evaluation (Performance, Bias, Fairness)
      {
        Name = "Evaluation"
        Type = "Processing"
        Arguments = {
          ProcessingResources = {
            ClusterConfig = {
              InstanceCount  = 1
              InstanceType   = var.evaluation_instance_type
              VolumeSizeInGB = 50
              VolumeKmsKeyId = var.kms_key_arn
            }
          }
          AppSpecification = {
            ImageUri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-model-evaluation:latest"
            ContainerArguments = [
              "--model-uri", "${local.pipeline_s3_prefix}/model-artifacts/",
              "--test-data-uri", "${local.pipeline_s3_prefix}/train-test-split/",
              "--output-uri", "${local.pipeline_s3_prefix}/evaluation/",
              "--bias-check", "true",
              "--fairness-check", "true",
              "--explainability", "true"
            ]
          }
          ProcessingInputs = [
            {
              InputName = "model-artifacts"
              S3Input = {
                S3Uri       = "${local.pipeline_s3_prefix}/model-artifacts/"
                LocalPath   = "/opt/ml/processing/input/model"
                S3DataType  = "S3Prefix"
                S3InputMode = "File"
              }
            },
            {
              InputName = "test-data"
              S3Input = {
                S3Uri       = "${local.pipeline_s3_prefix}/train-test-split/"
                LocalPath   = "/opt/ml/processing/input/test"
                S3DataType  = "S3Prefix"
                S3InputMode = "File"
              }
            }
          ]
          ProcessingOutputConfig = {
            Outputs = [
              {
                OutputName = "evaluation-report"
                S3Output = {
                  S3Uri        = "${local.pipeline_s3_prefix}/evaluation/"
                  LocalPath    = "/opt/ml/processing/output/evaluation"
                  S3UploadMode = "EndOfJob"
                }
              },
              {
                OutputName = "bias-report"
                S3Output = {
                  S3Uri        = "${local.pipeline_s3_prefix}/bias/"
                  LocalPath    = "/opt/ml/processing/output/bias"
                  S3UploadMode = "EndOfJob"
                }
              },
              {
                OutputName = "explainability-report"
                S3Output = {
                  S3Uri        = "${local.pipeline_s3_prefix}/explainability/"
                  LocalPath    = "/opt/ml/processing/output/explainability"
                  S3UploadMode = "EndOfJob"
                }
              }
            ]
            KmsKeyId = var.kms_key_arn
          }
          RoleArn = var.sagemaker_execution_role_arn
          NetworkConfig = {
            EnableInterContainerTrafficEncryption = true
            EnableNetworkIsolation                = false
            VpcConfig = {
              Subnets        = var.subnet_ids
              SecurityGroupIds = var.security_group_ids
            }
          }
          StoppingCondition = {
            MaxRuntimeInSeconds = 7200
          }
          Tags = [for k, v in var.mandatory_tags : { Key = k, Value = v }]
        }
      },
      # Step 4: Registration (Model Registry with approval)
      {
        Name = "Registration"
        Type = "RegisterModel"
        Arguments = {
          ModelPackageGroupName = var.model_package_group_name
          ModelApprovalStatus   = { "Get" = "Parameters.ModelApprovalStatus" }
          InferenceSpecification = {
            Containers = [
              {
                Image        = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.name_prefix}-advisory-inference:latest"
                ModelDataUrl = "${local.pipeline_s3_prefix}/model-artifacts/"
              }
            ]
            SupportedContentTypes        = ["application/json"]
            SupportedResponseMIMETypes   = ["application/json"]
            SupportedRealtimeInferenceInstanceTypes = [
              var.production_variant_instance_type,
              var.canary_variant_instance_type
            ]
          }
          ModelMetrics = {
            ModelQuality = {
              Statistics = {
                ContentType = "application/json"
                S3Uri       = "${local.pipeline_s3_prefix}/evaluation/metrics.json"
              }
            }
            Bias = {
              Report = {
                ContentType = "application/json"
                S3Uri       = "${local.pipeline_s3_prefix}/bias/bias_report.json"
              }
            }
            Explainability = {
              Report = {
                ContentType = "application/json"
                S3Uri       = "${local.pipeline_s3_prefix}/explainability/shap_report.json"
              }
            }
          }
          CustomerMetadataProperties = {
            DatasetVersion     = { "Get" = "Parameters.DatasetVersion" }
            TrainingInstanceType = { "Get" = "Parameters.TrainingInstanceType" }
            Algorithm          = "PPO"
            Framework          = "ray"
            PipelineExecutionId = ""
          }
        }
      }
    ]
  })

  tags = merge(local.ml_tags, {
    Name         = local.pipeline_name
    PipelineType = "Training"
  })
}

# =============================================================================
# SAGEMAKER PIPELINE SCHEDULE (Optional - trigger daily retraining)
# =============================================================================

resource "aws_cloudwatch_event_rule" "pipeline_schedule" {
  name                = "${local.pipeline_name}-weekly-schedule"
  description         = "Triggers advisory model retraining pipeline weekly"
  schedule_expression = "cron(0 2 ? * SUN *)"
  state               = var.environment == "production" ? "ENABLED" : "DISABLED"

  tags = merge(local.ml_tags, {
    Name = "${local.pipeline_name}-weekly-schedule"
  })
}

resource "aws_cloudwatch_event_target" "pipeline_target" {
  rule     = aws_cloudwatch_event_rule.pipeline_schedule.name
  arn      = "arn:aws:sagemaker:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:pipeline/${local.pipeline_name}"
  role_arn = var.sagemaker_execution_role_arn

  sagemaker_pipeline_target {
    pipeline_parameter_list {
      name  = "DatasetVersion"
      value = "latest"
    }
    pipeline_parameter_list {
      name  = "ModelApprovalStatus"
      value = "PendingManualApproval"
    }
  }
}

# =============================================================================
# S3 BUCKET FOR PIPELINE ARTIFACTS
# =============================================================================

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  bucket = var.model_artifacts_bucket_name

  rule {
    id     = "pipeline-artifacts-lifecycle"
    status = "Enabled"

    filter {
      prefix = "${var.name_prefix}/pipeline/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "endpoint-data-capture-lifecycle"
    status = "Enabled"

    filter {
      prefix = "${var.name_prefix}/endpoint-data-capture/"
    }

    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 90
    }
  }
}
