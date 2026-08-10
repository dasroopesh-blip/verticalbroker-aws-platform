# Step Functions Pipeline Orchestrator
# VerticalBroker AWS Data Engineering Platform
#
# Implements the ETL Pipeline Orchestrator state machine coordinating:
# ValidateInput → CheckPartition → BronzeToSilver → SilverToGold →
# TriggerIndexing (parallel: OpenSearch + Neptune) → EmitSuccess
#
# Requirements: 6.7 - Step Functions Orchestrator workflows for multi-step processes
# Requirements: 3.6 - ETL job failure after 3 retries emits failure event

# -----------------------------------------------------------------------------
# Local Variables
# -----------------------------------------------------------------------------

locals {
  step_functions_name = "${var.project_prefix}-pipeline-orchestrator"

  step_functions_tags = {
    Environment        = var.tag_environment
    Service            = "pipeline-orchestration"
    Owner              = var.tag_owner
    CostCenter         = var.tag_cost_center
    DataClassification = var.tag_data_classification
    Compliance         = var.tag_compliance
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for State Machine Execution History
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "pipeline_orchestrator" {
  name              = "/aws/stepfunctions/${local.step_functions_name}"
  retention_in_days = var.log_retention_days

  tags = local.step_functions_tags
}

# -----------------------------------------------------------------------------
# IAM Role for Step Functions
# Permissions: start Glue jobs, invoke Lambda, emit EventBridge events,
#              write CloudWatch logs
# -----------------------------------------------------------------------------

resource "aws_iam_role" "step_functions_orchestrator" {
  name = "${local.step_functions_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = local.step_functions_tags
}

# Policy: Start and monitor Glue ETL jobs
resource "aws_iam_role_policy" "step_functions_glue" {
  name = "${local.step_functions_name}-glue-policy"
  role = aws_iam_role.step_functions_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGlueJobExecution"
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:BatchStopJobRun"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:job/${var.project_prefix}-bronze-to-silver-etl",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:job/${var.project_prefix}-silver-to-gold-etl"
        ]
      }
    ]
  })
}

# Policy: Invoke Lambda functions (ValidateInput, indexing)
resource "aws_iam_role_policy" "step_functions_lambda" {
  name = "${local.step_functions_name}-lambda-policy"
  role = aws_iam_role.step_functions_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaInvocation"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-validate-pipeline-input",
          "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-update-opensearch-index",
          "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-update-neptune-graph"
        ]
      }
    ]
  })
}

# Policy: Emit events to EventBridge
resource "aws_iam_role_policy" "step_functions_eventbridge" {
  name = "${local.step_functions_name}-eventbridge-policy"
  role = aws_iam_role.step_functions_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePutEvents"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = [
          "arn:aws:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.project_prefix}-platform"
        ]
      }
    ]
  })
}

# Policy: Write CloudWatch logs for execution history
resource "aws_iam_role_policy" "step_functions_logging" {
  name = "${local.step_functions_name}-logging-policy"
  role = aws_iam_role.step_functions_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:CreateLogStream",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy: Allow X-Ray tracing for distributed tracing
resource "aws_iam_role_policy" "step_functions_xray" {
  name = "${local.step_functions_name}-xray-policy"
  role = aws_iam_role.step_functions_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowXRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Step Functions State Machine - Pipeline Orchestrator
# Flow: ValidateInput → CheckPartition → BronzeToSilver → SilverToGold →
#       TriggerIndexing (parallel: OpenSearch + Neptune) → EmitSuccess
# Error handling: Catch blocks route to EmitFailure state
# Retry logic: Glue jobs retry 3x with 60s interval and 2.0 backoff
# -----------------------------------------------------------------------------

resource "aws_sfn_state_machine" "pipeline_orchestrator" {
  name     = local.step_functions_name
  role_arn = aws_iam_role.step_functions_orchestrator.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "VerticalBroker ETL Pipeline Orchestrator - Coordinates multi-step data processing from Bronze through Gold layers with parallel indexing"
    StartAt = "ValidateInput"
    States = {
      # Step 1: Validate pipeline input parameters
      ValidateInput = {
        Type     = "Task"
        Resource = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-validate-pipeline-input"
        Comment  = "Validate input parameters: partition_path, source_id, schema_version"
        Next     = "CheckPartition"
        Catch = [
          {
            ErrorEquals = ["ValidationError", "States.TaskFailed"]
            Next        = "EmitError"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.validation_result"
      }

      # Step 2: Check if partition has already been processed (Choice state)
      CheckPartition = {
        Type    = "Choice"
        Comment = "Route based on partition processing status"
        Choices = [
          {
            Variable     = "$.validation_result.partition_status"
            StringEquals = "already_processed"
            Next         = "SkipProcessing"
          }
        ]
        Default = "TriggerBronzeToSilver"
      }

      # Step 3: Trigger Bronze to Silver Glue ETL job
      TriggerBronzeToSilver = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Comment  = "Execute Bronze-to-Silver ETL transformation with PySpark"
        Parameters = {
          JobName = "${var.project_prefix}-bronze-to-silver-etl"
          Arguments = {
            "--source_partition.$" = "$.partition_path"
            "--job_id.$"           = "$$.Execution.Id"
            "--source_id.$"        = "$.source_id"
            "--schema_version.$"   = "$.schema_version"
          }
        }
        Retry = [
          {
            ErrorEquals = [
              "Glue.AWSGlueException",
              "Glue.ConcurrentRunsExceededException",
              "Glue.JobRunException"
            ]
            IntervalSeconds = 60
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "EmitFailure"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.bronze_to_silver_result"
        Next       = "TriggerSilverToGold"
      }

      # Step 4: Trigger Silver to Gold Glue ETL job
      TriggerSilverToGold = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Comment  = "Execute Silver-to-Gold aggregation ETL with PySpark"
        Parameters = {
          JobName = "${var.project_prefix}-silver-to-gold-etl"
          Arguments = {
            "--source_partition.$" = "$.bronze_to_silver_result.Arguments.--output_path"
            "--job_id.$"           = "$$.Execution.Id"
          }
        }
        Retry = [
          {
            ErrorEquals = [
              "Glue.AWSGlueException",
              "Glue.ConcurrentRunsExceededException",
              "Glue.JobRunException"
            ]
            IntervalSeconds = 60
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "EmitFailure"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.silver_to_gold_result"
        Next       = "TriggerIndexing"
      }

      # Step 5: Parallel indexing - Update OpenSearch and Neptune simultaneously
      TriggerIndexing = {
        Type    = "Parallel"
        Comment = "Parallel execution: Update search index and graph database"
        Branches = [
          {
            StartAt = "UpdateOpenSearch"
            States = {
              UpdateOpenSearch = {
                Type     = "Task"
                Resource = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-update-opensearch-index"
                Comment  = "Index Gold layer data into OpenSearch for search and analytics"
                Parameters = {
                  "execution_id.$"   = "$$.Execution.Id"
                  "gold_output.$"    = "$.silver_to_gold_result"
                  "partition_path.$" = "$.partition_path"
                }
                Retry = [
                  {
                    ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
                    IntervalSeconds = 30
                    MaxAttempts     = 2
                    BackoffRate     = 2.0
                  }
                ]
                End = true
              }
            }
          },
          {
            StartAt = "UpdateNeptune"
            States = {
              UpdateNeptune = {
                Type     = "Task"
                Resource = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_prefix}-update-neptune-graph"
                Comment  = "Update Neptune graph database with relationship data from Gold layer"
                Parameters = {
                  "execution_id.$"   = "$$.Execution.Id"
                  "gold_output.$"    = "$.silver_to_gold_result"
                  "partition_path.$" = "$.partition_path"
                }
                Retry = [
                  {
                    ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
                    IntervalSeconds = 30
                    MaxAttempts     = 2
                    BackoffRate     = 2.0
                  }
                ]
                End = true
              }
            }
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "EmitFailure"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.indexing_results"
        Next       = "EmitSuccess"
      }

      # Terminal: Emit pipeline success event to EventBridge
      EmitSuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:putEvents"
        Comment  = "Emit pipeline.completed event to EventBridge"
        Parameters = {
          Entries = [
            {
              Source       = "verticalbroker.pipeline-orchestrator"
              EventBusName = "${var.project_prefix}-platform"
              DetailType   = "PipelineExecutionCompleted"
              Detail = {
                "execution_id.$"   = "$$.Execution.Id"
                "partition_path.$" = "$.partition_path"
                "source_id.$"      = "$.source_id"
                "status"           = "SUCCESS"
                "timestamp.$"      = "$$.State.EnteredTime"
              }
            }
          ]
        }
        End = true
      }

      # Terminal: Emit pipeline failure event to EventBridge
      EmitFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:putEvents"
        Comment  = "Emit pipeline.failed event to EventBridge (Requirement 3.6)"
        Parameters = {
          Entries = [
            {
              Source       = "verticalbroker.pipeline-orchestrator"
              EventBusName = "${var.project_prefix}-platform"
              DetailType   = "PipelineExecutionFailed"
              Detail = {
                "execution_id.$"   = "$$.Execution.Id"
                "partition_path.$" = "$.partition_path"
                "source_id.$"      = "$.source_id"
                "status"           = "FAILED"
                "error.$"          = "$.error"
                "timestamp.$"      = "$$.State.EnteredTime"
              }
            }
          ]
        }
        End = true
      }

      # Terminal: Emit validation error event to EventBridge
      EmitError = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:putEvents"
        Comment  = "Emit pipeline validation error event"
        Parameters = {
          Entries = [
            {
              Source       = "verticalbroker.pipeline-orchestrator"
              EventBusName = "${var.project_prefix}-platform"
              DetailType   = "PipelineValidationError"
              Detail = {
                "execution_id.$"   = "$$.Execution.Id"
                "partition_path.$" = "$.partition_path"
                "status"           = "VALIDATION_ERROR"
                "error.$"          = "$.error"
                "timestamp.$"      = "$$.State.EnteredTime"
              }
            }
          ]
        }
        End = true
      }

      # Terminal: Skip processing for already-processed partitions
      SkipProcessing = {
        Type    = "Succeed"
        Comment = "Partition already processed - skip without error"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.pipeline_orchestrator.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.step_functions_tags
}

# -----------------------------------------------------------------------------
# Variables for Step Functions Module
# -----------------------------------------------------------------------------

variable "tag_environment" {
  description = "Mandatory tag: Environment"
  type        = string
}

variable "tag_owner" {
  description = "Mandatory tag: Owner"
  type        = string
}

variable "tag_cost_center" {
  description = "Mandatory tag: CostCenter"
  type        = string
}

variable "tag_data_classification" {
  description = "Mandatory tag: DataClassification"
  type        = string
}

variable "tag_compliance" {
  description = "Mandatory tag: Compliance"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for resource ARN construction"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "pipeline_orchestrator_arn" {
  description = "ARN of the pipeline orchestrator Step Functions state machine"
  value       = aws_sfn_state_machine.pipeline_orchestrator.arn
}

output "pipeline_orchestrator_name" {
  description = "Name of the pipeline orchestrator state machine"
  value       = aws_sfn_state_machine.pipeline_orchestrator.name
}

output "step_functions_role_arn" {
  description = "ARN of the IAM role used by the Step Functions state machine"
  value       = aws_iam_role.step_functions_orchestrator.arn
}

output "pipeline_orchestrator_log_group_arn" {
  description = "ARN of the CloudWatch log group for state machine execution history"
  value       = aws_cloudwatch_log_group.pipeline_orchestrator.arn
}
