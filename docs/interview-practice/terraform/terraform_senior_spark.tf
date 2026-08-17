# =============================================================================
# SENIOR DEVELOPER'S TERRAFORM — Spark/EMR + Glue Infrastructure
# =============================================================================
# Production Terraform for Vertical Broker's trade data ETL platform.
# Deploys: EMR Serverless, Glue Catalog, S3 data lake, IAM, monitoring.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "verticalbroker-terraform-state"
    key            = "data-platform/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# =============================================================================
# VARIABLES
# =============================================================================

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "emr_release_label" {
  description = "EMR release version"
  type        = string
  default     = "emr-7.0.0"
}

variable "spark_executor_memory" {
  description = "Spark executor memory"
  type        = string
  default     = "4g"
}

variable "spark_executor_cores" {
  description = "Spark executor cores"
  type        = number
  default     = 4
}

variable "max_concurrent_runs" {
  description = "Maximum concurrent EMR Serverless job runs"
  type        = number
  default     = 10
}

variable "alarm_email" {
  description = "Email for alerting"
  type        = string
  sensitive   = true
}

locals {
  project_name = "verticalbroker"
  service_name = "trade-etl"
  name_prefix  = "${local.project_name}-${var.environment}"

  common_tags = {
    Project     = local.project_name
    Service     = local.service_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "data-engineering"
    CostCenter  = "data-platform"
  }

  # Data lake bucket structure
  raw_bucket_name         = "${local.name_prefix}-raw-trades"
  processed_bucket_name   = "${local.name_prefix}-processed-trades"
  dead_letter_bucket_name = "${local.name_prefix}-dead-letter"
  scripts_bucket_name     = "${local.name_prefix}-etl-scripts"
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

# =============================================================================
# S3 DATA LAKE — Raw, Processed, Dead Letter, Scripts
# =============================================================================

# --- Raw trades (landing zone) ---
resource "aws_s3_bucket" "raw_trades" {
  bucket = local.raw_bucket_name

  tags = {
    Name      = local.raw_bucket_name
    DataClass = "raw"
    DataTier  = "landing"
  }
}

resource "aws_s3_bucket_versioning" "raw_trades" {
  bucket = aws_s3_bucket.raw_trades.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_trades" {
  bucket = aws_s3_bucket.raw_trades.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw_trades" {
  bucket                  = aws_s3_bucket.raw_trades.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_trades" {
  bucket = aws_s3_bucket.raw_trades.id

  rule {
    id     = "archive-raw-data"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 2555 # 7 years for regulatory compliance
    }
  }
}

# --- Processed trades (curated zone) ---
resource "aws_s3_bucket" "processed_trades" {
  bucket = local.processed_bucket_name

  tags = {
    Name      = local.processed_bucket_name
    DataClass = "processed"
    DataTier  = "curated"
  }
}

resource "aws_s3_bucket_versioning" "processed_trades" {
  bucket = aws_s3_bucket.processed_trades.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_trades" {
  bucket = aws_s3_bucket.processed_trades.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "processed_trades" {
  bucket                  = aws_s3_bucket.processed_trades.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Dead letter bucket ---
resource "aws_s3_bucket" "dead_letter" {
  bucket = local.dead_letter_bucket_name

  tags = {
    Name      = local.dead_letter_bucket_name
    DataClass = "error"
    DataTier  = "investigation"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dead_letter" {
  bucket = aws_s3_bucket.dead_letter.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "dead_letter" {
  bucket                  = aws_s3_bucket.dead_letter.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- ETL Scripts bucket ---
resource "aws_s3_bucket" "scripts" {
  bucket = local.scripts_bucket_name

  tags = {
    Name = local.scripts_bucket_name
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  bucket = aws_s3_bucket.scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload ETL script
resource "aws_s3_object" "etl_script" {
  bucket = aws_s3_bucket.scripts.id
  key    = "spark/trade_etl.py"
  source = "${path.module}/src/spark_senior_etl.py"
  etag   = filemd5("${path.module}/src/spark_senior_etl.py")
}

# =============================================================================
# EMR SERVERLESS — Spark Application
# =============================================================================

resource "aws_emrserverless_application" "trade_etl" {
  name          = "${local.name_prefix}-trade-etl"
  release_label = var.emr_release_label
  type          = "spark"

  initial_capacity {
    initial_capacity_type = "Driver"

    initial_capacity_config {
      worker_count = 1
      worker_configuration {
        cpu    = "2 vCPU"
        memory = "4 GB"
      }
    }
  }

  initial_capacity {
    initial_capacity_type = "Executor"

    initial_capacity_config {
      worker_count = 4
      worker_configuration {
        cpu    = "${var.spark_executor_cores} vCPU"
        memory = var.spark_executor_memory
      }
    }
  }

  maximum_capacity {
    cpu    = var.environment == "prod" ? "200 vCPU" : "50 vCPU"
    memory = var.environment == "prod" ? "400 GB" : "100 GB"
  }

  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = 5
  }

  network_configuration {
    subnet_ids         = var.environment == "prod" ? data.aws_subnets.private.ids : []
    security_group_ids = var.environment == "prod" ? [aws_security_group.emr[0].id] : []
  }

  tags = {
    Name = "${local.name_prefix}-trade-etl"
  }
}

# =============================================================================
# GLUE CATALOG — Data Lake Metadata
# =============================================================================

resource "aws_glue_catalog_database" "trade_data" {
  name = "${local.name_prefix}_trades"

  create_table_default_permission {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }
}

resource "aws_glue_catalog_table" "processed_trades" {
  name          = "processed_trades"
  database_name = aws_glue_catalog_database.trade_data.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "parquet"
    "parquet.compress" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.processed_trades.bucket}/processed/trades/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "request_id"
      type = "string"
    }
    columns {
      name = "customer_id"
      type = "string"
    }
    columns {
      name = "symbol"
      type = "string"
    }
    columns {
      name = "quantity"
      type = "int"
    }
    columns {
      name = "price"
      type = "decimal(12,4)"
    }
    columns {
      name = "side"
      type = "string"
    }
    columns {
      name = "total_amount"
      type = "decimal(18,2)"
    }
    columns {
      name = "processed_at"
      type = "timestamp"
    }
  }

  partition_keys {
    name = "trade_date"
    type = "date"
  }

  partition_keys {
    name = "symbol"
    type = "string"
  }
}

# =============================================================================
# IAM — Least Privilege for EMR Serverless
# =============================================================================

resource "aws_iam_role" "emr_execution_role" {
  name = "${local.name_prefix}-emr-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "emr-serverless.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-emr-execution-role"
  }
}

# S3 access — specific buckets, specific actions
resource "aws_iam_role_policy" "emr_s3_access" {
  name = "s3-data-access"
  role = aws_iam_role.emr_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawData"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw_trades.arn,
          "${aws_s3_bucket.raw_trades.arn}/*"
        ]
      },
      {
        Sid    = "WriteProcessedData"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.processed_trades.arn,
          "${aws_s3_bucket.processed_trades.arn}/*"
        ]
      },
      {
        Sid    = "WriteDeadLetter"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.dead_letter.arn}/*"
        ]
      },
      {
        Sid    = "ReadScripts"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      }
    ]
  })
}

# Glue Catalog access
resource "aws_iam_role_policy" "emr_glue_access" {
  name = "glue-catalog-access"
  role = aws_iam_role.emr_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "glue:GetDatabase",
        "glue:GetTable",
        "glue:GetPartitions",
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:CreatePartition",
        "glue:BatchCreatePartition"
      ]
      Resource = [
        "arn:aws:glue:*:*:catalog",
        "arn:aws:glue:*:*:database/${aws_glue_catalog_database.trade_data.name}",
        "arn:aws:glue:*:*:table/${aws_glue_catalog_database.trade_data.name}/*"
      ]
    }]
  })
}

# CloudWatch Logs
resource "aws_iam_role_policy" "emr_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.emr_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:*:*:log-group:/aws/emr-serverless/*"
    }]
  })
}

# =============================================================================
# STEP FUNCTIONS — Orchestration (replaces manual job submission)
# =============================================================================

resource "aws_sfn_state_machine" "trade_etl_orchestrator" {
  name     = "${local.name_prefix}-trade-etl-orchestrator"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "Orchestrates daily trade ETL pipeline"
    StartAt = "SubmitSparkJob"
    States = {
      SubmitSparkJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::emr-serverless:startJobRun.sync"
        Parameters = {
          ApplicationId = aws_emrserverless_application.trade_etl.id
          ExecutionRoleArn = aws_iam_role.emr_execution_role.arn
          Name = "trade-etl-${var.environment}"
          JobDriver = {
            SparkSubmit = {
              EntryPoint = "s3://${aws_s3_bucket.scripts.bucket}/spark/trade_etl.py"
              EntryPointArguments = [
                "--environment", var.environment,
                "--run-date.$", "$.run_date",
                "--source-bucket", aws_s3_bucket.raw_trades.bucket,
                "--target-bucket", aws_s3_bucket.processed_trades.bucket,
                "--dead-letter-bucket", aws_s3_bucket.dead_letter.bucket
              ]
              SparkSubmitParameters = join(" ", [
                "--conf spark.executor.memory=${var.spark_executor_memory}",
                "--conf spark.executor.cores=${var.spark_executor_cores}",
                "--conf spark.sql.adaptive.enabled=true",
                "--conf spark.sql.shuffle.partitions=50",
              ])
            }
          }
          ConfigurationOverrides = {
            MonitoringConfiguration = {
              S3MonitoringConfiguration = {
                LogUri = "s3://${aws_s3_bucket.scripts.bucket}/logs/"
              }
            }
          }
        }
        Next = "CheckResults"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
        }]
      }
      CheckResults = {
        Type = "Pass"
        Next = "NotifySuccess"
      }
      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Message  = "Trade ETL completed successfully"
          Subject  = "✅ Trade ETL Success"
        }
        End = true
      }
      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Message  = "Trade ETL FAILED — investigate immediately"
          Subject  = "🚨 Trade ETL FAILURE"
        }
        End = true
      }
    }
  })

  tags = {
    Name = "${local.name_prefix}-trade-etl-orchestrator"
  }
}

# Step Functions IAM Role
resource "aws_iam_role" "step_functions_role" {
  name = "${local.name_prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "sfn_emr_policy" {
  name = "emr-serverless-access"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "emr-serverless:StartJobRun",
          "emr-serverless:GetJobRun"
        ]
        Resource = aws_emrserverless_application.trade_etl.arn
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.emr_execution_role.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.etl_alerts.arn
      }
    ]
  })
}

# =============================================================================
# EVENTBRIDGE — Daily Schedule
# =============================================================================

resource "aws_scheduler_schedule" "daily_etl" {
  name       = "${local.name_prefix}-daily-trade-etl"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  # Run at 2:00 AM UTC daily (after market close + settlement)
  schedule_expression = "cron(0 2 * * ? *)"

  target {
    arn      = aws_sfn_state_machine.trade_etl_orchestrator.arn
    role_arn = aws_iam_role.scheduler_role.arn

    input = jsonencode({
      run_date = "today"  # Step Function will resolve to actual date
    })
  }
}

resource "aws_iam_role" "scheduler_role" {
  name = "${local.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_sfn" {
  name = "start-step-function"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.trade_etl_orchestrator.arn
    }]
  })
}

# =============================================================================
# MONITORING
# =============================================================================

resource "aws_sns_topic" "etl_alerts" {
  name = "${local.name_prefix}-etl-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.etl_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Alarm: Dead letter bucket has new objects (failed records)
resource "aws_cloudwatch_metric_alarm" "dead_letter_objects" {
  alarm_name          = "${local.name_prefix}-dead-letter-objects"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "NumberOfObjects"
  namespace           = "AWS/S3"
  period              = 86400
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Failed trade records detected in dead letter bucket"
  alarm_actions       = [aws_sns_topic.etl_alerts.arn]

  dimensions = {
    BucketName  = aws_s3_bucket.dead_letter.bucket
    StorageType = "AllStorageTypes"
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "emr_application_id" {
  description = "EMR Serverless application ID"
  value       = aws_emrserverless_application.trade_etl.id
}

output "raw_bucket" {
  description = "Raw trades landing zone bucket"
  value       = aws_s3_bucket.raw_trades.bucket
}

output "processed_bucket" {
  description = "Processed trades curated zone bucket"
  value       = aws_s3_bucket.processed_trades.bucket
}

output "dead_letter_bucket" {
  description = "Dead letter bucket for failed records"
  value       = aws_s3_bucket.dead_letter.bucket
}

output "glue_database" {
  description = "Glue Catalog database name"
  value       = aws_glue_catalog_database.trade_data.name
}

output "step_function_arn" {
  description = "Step Function orchestrator ARN"
  value       = aws_sfn_state_machine.trade_etl_orchestrator.arn
}
