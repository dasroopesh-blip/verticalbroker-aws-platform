# =============================================================================
# SENIOR DEVELOPER'S TERRAFORM — Glue ETL (Bronze/Silver/Gold)
# =============================================================================
# Production-ready Terraform for Vertical Broker's data lakehouse.
# Deploys: 3 Glue jobs (Bronze/Silver/Gold), Glue Catalog, S3 data lake layers,
# Step Functions orchestration, scheduling, IAM least-privilege, monitoring.
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
    key            = "data-lake/terraform.tfstate"
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
    error_message = "Must be dev, staging, or prod."
  }
}

variable "glue_version" {
  description = "Glue version"
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type"
  type        = string
  default     = "G.2X" # 8 vCPU, 32 GB RAM per worker
}

variable "bronze_workers" {
  description = "Number of workers for Bronze job"
  type        = number
  default     = 5
}

variable "silver_workers" {
  description = "Number of workers for Silver job"
  type        = number
  default     = 10
}

variable "gold_workers" {
  description = "Number of workers for Gold job"
  type        = number
  default     = 5
}

variable "job_timeout_minutes" {
  description = "Maximum job runtime in minutes"
  type        = number
  default     = 60
}

variable "alarm_email" {
  description = "Email for alerting"
  type        = string
  sensitive   = true
}

locals {
  project_name = "verticalbroker"
  service_name = "trade-data-lake"
  name_prefix  = "${local.project_name}-${var.environment}"

  common_tags = {
    Project     = local.project_name
    Service     = local.service_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "data-engineering"
    CostCenter  = "data-platform"
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = local.common_tags
  }
}

# =============================================================================
# S3 DATA LAKE — Separate buckets per layer
# =============================================================================

# --- Module pattern for DRY bucket creation ---
locals {
  data_buckets = {
    raw = {
      name      = "${local.name_prefix}-raw-trades"
      data_tier = "landing"
      lifecycle_ia_days      = 30
      lifecycle_glacier_days = 90
      lifecycle_expire_days  = 2555
    }
    bronze = {
      name      = "${local.name_prefix}-bronze"
      data_tier = "bronze"
      lifecycle_ia_days      = 60
      lifecycle_glacier_days = 180
      lifecycle_expire_days  = 2555
    }
    silver = {
      name      = "${local.name_prefix}-silver"
      data_tier = "silver"
      lifecycle_ia_days      = 90
      lifecycle_glacier_days = 365
      lifecycle_expire_days  = 2555
    }
    gold = {
      name      = "${local.name_prefix}-gold"
      data_tier = "gold"
      lifecycle_ia_days      = 180
      lifecycle_glacier_days = 730
      lifecycle_expire_days  = 2555
    }
    dead_letter = {
      name      = "${local.name_prefix}-dead-letter"
      data_tier = "error"
      lifecycle_ia_days      = 30
      lifecycle_glacier_days = 90
      lifecycle_expire_days  = 365
    }
    scripts = {
      name      = "${local.name_prefix}-etl-scripts"
      data_tier = "infrastructure"
      lifecycle_ia_days      = 0
      lifecycle_glacier_days = 0
      lifecycle_expire_days  = 0
    }
  }
}

resource "aws_s3_bucket" "data_lake" {
  for_each = local.data_buckets
  bucket   = each.value.name

  tags = {
    Name      = each.value.name
    DataTier  = each.value.data_tier
    DataClass = "financial"
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  for_each = local.data_buckets
  bucket   = aws_s3_bucket.data_lake[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  for_each = local.data_buckets
  bucket   = aws_s3_bucket.data_lake[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  for_each = local.data_buckets
  bucket   = aws_s3_bucket.data_lake[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# GLUE CATALOG — Separate databases per layer
# =============================================================================

resource "aws_glue_catalog_database" "bronze" {
  name = "${local.name_prefix}_bronze"
}

resource "aws_glue_catalog_database" "silver" {
  name = "${local.name_prefix}_silver"
}

resource "aws_glue_catalog_database" "gold" {
  name = "${local.name_prefix}_gold"
}

# =============================================================================
# GLUE JOBS — One per layer (separation of concerns)
# =============================================================================

# --- Upload job scripts ---
resource "aws_s3_object" "bronze_script" {
  bucket = aws_s3_bucket.data_lake["scripts"].id
  key    = "glue/bronze/trade_etl_bronze.py"
  source = "${path.module}/src/glue_senior_bronze.py"
  etag   = filemd5("${path.module}/src/glue_senior_bronze.py")
}

resource "aws_s3_object" "silver_script" {
  bucket = aws_s3_bucket.data_lake["scripts"].id
  key    = "glue/silver/trade_etl_silver.py"
  source = "${path.module}/src/glue_senior_silver.py"
  etag   = filemd5("${path.module}/src/glue_senior_silver.py")
}

resource "aws_s3_object" "gold_script" {
  bucket = aws_s3_bucket.data_lake["scripts"].id
  key    = "glue/gold/trade_etl_gold.py"
  source = "${path.module}/src/glue_senior_gold.py"
  etag   = filemd5("${path.module}/src/glue_senior_gold.py")
}

# --- Bronze Job ---
resource "aws_glue_job" "bronze" {
  name     = "${local.name_prefix}-trade-etl-bronze"
  role_arn = aws_iam_role.glue_role.arn

  glue_version = var.glue_version

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/glue/bronze/trade_etl_bronze.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.bronze_workers
  timeout           = var.job_timeout_minutes

  # Job bookmarks — prevent reprocessing same files
  default_arguments = {
    "--job-bookmark-option"   = "job-bookmark-enable"
    "--environment"           = var.environment
    "--source_path"           = "s3://${aws_s3_bucket.data_lake["raw"].bucket}/trades/"
    "--bronze_path"           = "s3://${aws_s3_bucket.data_lake["bronze"].bucket}/trades/"
    "--dead_letter_path"      = "s3://${aws_s3_bucket.data_lake["dead_letter"].bucket}/"
    "--glue_database"         = aws_glue_catalog_database.bronze.name
    "--enable_bookmarks"      = "true"
    "--enable-metrics"        = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/spark-ui-logs/bronze/"
  }

  execution_property {
    max_concurrent_runs = 1 # Only one Bronze run at a time
  }

  tags = {
    Name     = "${local.name_prefix}-bronze"
    DataTier = "bronze"
  }
}

# --- Silver Job ---
resource "aws_glue_job" "silver" {
  name     = "${local.name_prefix}-trade-etl-silver"
  role_arn = aws_iam_role.glue_role.arn

  glue_version = var.glue_version

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/glue/silver/trade_etl_silver.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.silver_workers
  timeout           = var.job_timeout_minutes

  default_arguments = {
    "--job-bookmark-option"   = "job-bookmark-enable"
    "--environment"           = var.environment
    "--bronze_path"           = "s3://${aws_s3_bucket.data_lake["bronze"].bucket}/trades/"
    "--silver_path"           = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/trades/"
    "--dead_letter_path"      = "s3://${aws_s3_bucket.data_lake["dead_letter"].bucket}/"
    "--bronze_database"       = aws_glue_catalog_database.bronze.name
    "--silver_database"       = aws_glue_catalog_database.silver.name
    "--enable-metrics"        = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/spark-ui-logs/silver/"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name     = "${local.name_prefix}-silver"
    DataTier = "silver"
  }
}

# --- Gold Job ---
resource "aws_glue_job" "gold" {
  name     = "${local.name_prefix}-trade-etl-gold"
  role_arn = aws_iam_role.glue_role.arn

  glue_version = var.glue_version

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/glue/gold/trade_etl_gold.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.gold_workers
  timeout           = var.job_timeout_minutes

  default_arguments = {
    "--job-bookmark-option"   = "job-bookmark-enable"
    "--environment"           = var.environment
    "--silver_path"           = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/trades/"
    "--gold_path"             = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/"
    "--silver_database"       = aws_glue_catalog_database.silver.name
    "--gold_database"         = aws_glue_catalog_database.gold.name
    "--enable-metrics"        = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"       = "true"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.data_lake["scripts"].bucket}/spark-ui-logs/gold/"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name     = "${local.name_prefix}-gold"
    DataTier = "gold"
  }
}

# =============================================================================
# IAM — Least Privilege for Glue
# =============================================================================

resource "aws_iam_role" "glue_role" {
  name = "${local.name_prefix}-glue-etl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

# Basic Glue service role (logs, metrics)
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# S3 access — per-bucket, per-action
resource "aws_iam_role_policy" "glue_s3" {
  name = "s3-data-lake-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawData"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake["raw"].arn,
          "${aws_s3_bucket.data_lake["raw"].arn}/*"
        ]
      },
      {
        Sid    = "ReadWriteBronze"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake["bronze"].arn,
          "${aws_s3_bucket.data_lake["bronze"].arn}/*"
        ]
      },
      {
        Sid    = "ReadWriteSilver"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake["silver"].arn,
          "${aws_s3_bucket.data_lake["silver"].arn}/*"
        ]
      },
      {
        Sid    = "ReadWriteGold"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake["gold"].arn,
          "${aws_s3_bucket.data_lake["gold"].arn}/*"
        ]
      },
      {
        Sid    = "WriteDeadLetter"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.data_lake["dead_letter"].arn}/*"]
      },
      {
        Sid    = "ReadScripts"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.data_lake["scripts"].arn}/*"]
      }
    ]
  })
}

# Glue Catalog access
resource "aws_iam_role_policy" "glue_catalog" {
  name = "glue-catalog-access"
  role = aws_iam_role.glue_role.id

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
        "glue:DeleteTable",
        "glue:CreatePartition",
        "glue:BatchCreatePartition",
        "glue:UpdatePartition"
      ]
      Resource = [
        "arn:aws:glue:*:*:catalog",
        "arn:aws:glue:*:*:database/${aws_glue_catalog_database.bronze.name}",
        "arn:aws:glue:*:*:database/${aws_glue_catalog_database.silver.name}",
        "arn:aws:glue:*:*:database/${aws_glue_catalog_database.gold.name}",
        "arn:aws:glue:*:*:table/${aws_glue_catalog_database.bronze.name}/*",
        "arn:aws:glue:*:*:table/${aws_glue_catalog_database.silver.name}/*",
        "arn:aws:glue:*:*:table/${aws_glue_catalog_database.gold.name}/*"
      ]
    }]
  })
}

# =============================================================================
# STEP FUNCTIONS — Orchestrate Bronze → Silver → Gold
# =============================================================================

resource "aws_sfn_state_machine" "etl_pipeline" {
  name     = "${local.name_prefix}-trade-etl-pipeline"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    Comment = "Orchestrates Bronze → Silver → Gold ETL pipeline"
    StartAt = "RunBronze"
    States = {
      RunBronze = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.bronze.name
          Arguments = {
            "--run_date.$" = "$.run_date"
          }
        }
        Next  = "RunSilver"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "BronzeFailed"
        }]
      }
      RunSilver = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.silver.name
          Arguments = {
            "--run_date.$" = "$.run_date"
          }
        }
        Next  = "RunGold"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "SilverFailed"
        }]
      }
      RunGold = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.gold.name
          Arguments = {
            "--run_date.$" = "$.run_date"
          }
        }
        Next  = "PipelineSuccess"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "GoldFailed"
        }]
      }
      PipelineSuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Subject  = "✅ Trade ETL Pipeline Success"
          Message  = "Bronze → Silver → Gold completed successfully"
        }
        End = true
      }
      BronzeFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Subject  = "🚨 BRONZE ETL FAILED"
          Message  = "Bronze job failed — Silver and Gold will NOT run"
        }
        End = true
      }
      SilverFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Subject  = "🚨 SILVER ETL FAILED"
          Message  = "Silver job failed — Gold will NOT run. Bronze data is intact."
        }
        End = true
      }
      GoldFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.etl_alerts.arn
          Subject  = "⚠️ GOLD ETL FAILED"
          Message  = "Gold aggregation failed — Silver data is intact. Dashboards may be stale."
        }
        End = true
      }
    }
  })

  tags = {
    Name = "${local.name_prefix}-etl-pipeline"
  }
}

# Step Functions IAM
resource "aws_iam_role" "sfn_role" {
  name = "${local.name_prefix}-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sfn_glue" {
  name = "glue-job-access"
  role = aws_iam_role.sfn_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = [
          aws_glue_job.bronze.arn,
          aws_glue_job.silver.arn,
          aws_glue_job.gold.arn,
        ]
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

  # Run at 2:00 AM UTC (after US market close + settlement)
  schedule_expression = "cron(0 2 * * ? *)"

  target {
    arn      = aws_sfn_state_machine.etl_pipeline.arn
    role_arn = aws_iam_role.scheduler_role.arn

    input = jsonencode({
      run_date = "<aws.scheduler.execution-id>" # Resolved at runtime
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
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_sfn" {
  name = "start-pipeline"
  role = aws_iam_role.scheduler_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.etl_pipeline.arn
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

# Alarm: Any Glue job failure
resource "aws_cloudwatch_metric_alarm" "glue_failures" {
  for_each = toset(["bronze", "silver", "gold"])

  alarm_name          = "${local.name_prefix}-${each.key}-job-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "${each.key} Glue job has failed tasks"
  alarm_actions       = [aws_sns_topic.etl_alerts.arn]

  dimensions = {
    JobName = "${local.name_prefix}-trade-etl-${each.key}"
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "bronze_bucket" {
  value = aws_s3_bucket.data_lake["bronze"].bucket
}

output "silver_bucket" {
  value = aws_s3_bucket.data_lake["silver"].bucket
}

output "gold_bucket" {
  value = aws_s3_bucket.data_lake["gold"].bucket
}

output "step_function_arn" {
  value = aws_sfn_state_machine.etl_pipeline.arn
}

output "bronze_job_name" {
  value = aws_glue_job.bronze.name
}

output "silver_job_name" {
  value = aws_glue_job.silver.name
}

output "gold_job_name" {
  value = aws_glue_job.gold.name
}
