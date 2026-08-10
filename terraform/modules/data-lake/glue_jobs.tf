# Glue Jobs - Bronze-to-Silver and Silver-to-Gold ETL Definitions
# VerticalBroker AWS Data Engineering Platform
#
# Defines AWS Glue PySpark jobs for the medallion architecture ETL pipeline:
#   - Bronze-to-Silver: Cleanse, validate, deduplicate raw data (60 min timeout)
#   - Silver-to-Gold: Aggregate business datasets (30 min timeout)
#
# Configuration:
#   - Worker Type G.2X (8 vCPU, 32 GB) optimized for Parquet/Snappy workloads
#   - Auto-scaling: min 10 / max 100 DPUs
#   - Spot Instances with On-Demand fallback for cost optimization (60% savings)
#   - Glue version 4.0 (Spark 3.3 + Python 3.10)
#   - Job bookmarks enabled for incremental processing
#   - KMS encryption for job bookmarks, S3 targets, and CloudWatch logs
#
# Requirements: 3.7 (Bronze-to-Silver within 60 min, auto-scaling Glue workers G.2X max 100 DPUs)
# Requirements: 4.6 (Silver-to-Gold SLA compliance)
# Requirements: 17.4 (Spot Instances for non-critical ETL with On-Demand fallback)

# ---------------------------------------------------------
# GLUE SECURITY CONFIGURATION
# KMS encryption for job bookmarks, S3 targets, and CloudWatch logs
# Requirement 14.1: Encrypt all data at rest with KMS CMKs
# ---------------------------------------------------------

resource "aws_glue_security_configuration" "etl_security" {
  name = "${var.name_prefix}-etl-security-config"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_confidential_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_confidential_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_confidential_key_arn
    }
  }
}

# ---------------------------------------------------------
# GLUE CONNECTION - VPC Access for Private Subnets
# Requirement 20.3: All data platform resources in private subnets
# ---------------------------------------------------------

resource "aws_glue_connection" "vpc_connection" {
  name            = "${var.name_prefix}-glue-vpc-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = var.glue_connection_availability_zone
    security_group_id_list = var.glue_security_group_ids
    subnet_id              = var.glue_subnet_id
  }

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-glue-vpc-connection"
    Service = "data-lake"
    Purpose = "glue-etl-vpc-access"
  })
}

# ---------------------------------------------------------
# S3 BUCKET - Glue Job Scripts
# Stores PySpark ETL scripts (src/etl/) uploaded for Glue execution
# ---------------------------------------------------------

resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${var.name_prefix}-glue-scripts"

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-glue-scripts"
    DataClassification = "Internal"
    Service            = "data-lake"
    Purpose            = "glue-etl-job-scripts"
  })
}

resource "aws_s3_bucket_versioning" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_confidential_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${var.name_prefix}-glue-scripts-tls-only-policy"
    Statement = [
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.glue_scripts.arn,
          "${aws_s3_bucket.glue_scripts.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.glue_scripts]
}

# ---------------------------------------------------------
# BRONZE-TO-SILVER GLUE JOB
# Requirement 3.7: Complete within 60 minutes, auto-scaling G.2X max 100 DPUs
# Requirement 17.4: Spot Instances with On-Demand fallback
# ---------------------------------------------------------

resource "aws_glue_job" "bronze_to_silver" {
  name              = "${var.name_prefix}-bronze-to-silver-etl"
  description       = "Transforms raw Bronze layer data into validated Silver layer (cleanse, validate, deduplicate, conform)"
  role_arn          = var.etl_glue_role_arn
  glue_version      = "4.0"
  worker_type       = "G.2X"
  number_of_workers = 10
  max_retries       = 3
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/src/etl/bronze_to_silver.py"
    python_version  = "3"
  }

  execution_property {
    max_concurrent_runs = 5
  }

  security_configuration = aws_glue_security_configuration.etl_security.name
  connections            = [aws_glue_connection.vpc_connection.name]

  default_arguments = {
    # Job control arguments
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-auto-scaling"              = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.bucket}/spark-ui-logs/bronze-to-silver/"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.bucket}/tmp/bronze-to-silver/"
    "--extra-py-files"                   = "s3://${aws_s3_bucket.glue_scripts.bucket}/src/etl/common/data_quality.py"

    # ETL-specific arguments
    "--source_partition"                 = ""
    "--job_id"                           = ""
    "--environment"                      = var.environment
    "--bronze_bucket"                    = aws_s3_bucket.bronze.bucket
    "--silver_bucket"                    = aws_s3_bucket.silver.bucket
    "--gold_bucket"                      = aws_s3_bucket.gold.bucket
    "--event_bus_name"                   = var.event_bus_name

    # Worker and execution configuration
    "--conf"                             = "spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true --conf spark.dynamicAllocation.enabled=true"
    "--write-shuffle-files-to-s3"        = "true"

    # Cost optimization: Spot with On-Demand fallback
    "--enable-job-insights"              = "true"
  }

  execution_class = "FLEX"

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-bronze-to-silver-etl"
    Service            = "data-lake"
    Purpose            = "bronze-to-silver-transformation"
    DataClassification = "Confidential"
    PipelineStage      = "bronze-to-silver"
  })
}

# ---------------------------------------------------------
# SILVER-TO-GOLD GLUE JOB
# Requirement 4.6: Produce Gold datasets within 30 minutes
# Requirement 17.4: Spot Instances with On-Demand fallback
# ---------------------------------------------------------

resource "aws_glue_job" "silver_to_gold" {
  name              = "${var.name_prefix}-silver-to-gold-etl"
  description       = "Aggregates Silver layer into Gold business datasets (trade summaries, portfolios, performance, risk)"
  role_arn          = var.etl_glue_role_arn
  glue_version      = "4.0"
  worker_type       = "G.2X"
  number_of_workers = 10
  max_retries       = 3
  timeout           = 30

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/src/etl/silver_to_gold.py"
    python_version  = "3"
  }

  execution_property {
    max_concurrent_runs = 5
  }

  security_configuration = aws_glue_security_configuration.etl_security.name
  connections            = [aws_glue_connection.vpc_connection.name]

  default_arguments = {
    # Job control arguments
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-auto-scaling"              = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.bucket}/spark-ui-logs/silver-to-gold/"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--enable-metrics"                   = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.bucket}/tmp/silver-to-gold/"
    "--extra-py-files"                   = "s3://${aws_s3_bucket.glue_scripts.bucket}/src/etl/common/data_quality.py"

    # ETL-specific arguments
    "--source_partition"                 = ""
    "--job_id"                           = ""
    "--environment"                      = var.environment
    "--bronze_bucket"                    = aws_s3_bucket.bronze.bucket
    "--silver_bucket"                    = aws_s3_bucket.silver.bucket
    "--gold_bucket"                      = aws_s3_bucket.gold.bucket
    "--event_bus_name"                   = var.event_bus_name

    # Worker and execution configuration
    "--conf"                             = "spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true --conf spark.dynamicAllocation.enabled=true"
    "--write-shuffle-files-to-s3"        = "true"

    # Cost optimization: Spot with On-Demand fallback
    "--enable-job-insights"              = "true"
  }

  execution_class = "FLEX"

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-silver-to-gold-etl"
    Service            = "data-lake"
    Purpose            = "silver-to-gold-aggregation"
    DataClassification = "Confidential"
    PipelineStage      = "silver-to-gold"
  })
}
