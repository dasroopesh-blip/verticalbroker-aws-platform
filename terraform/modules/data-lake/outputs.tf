# Data Lake Module Outputs
# VerticalBroker AWS Data Engineering Platform
# Exports S3 bucket references, Glue catalog database/table references,
# crawler ARNs, and Lake Formation resources for consumption by
# compute, analytics, and monitoring modules

# ---------------------------------------------------------
# S3 BUCKET OUTPUTS
# ---------------------------------------------------------

output "bronze_bucket_id" {
  description = "ID of the Bronze layer S3 bucket"
  value       = aws_s3_bucket.bronze.id
}

output "bronze_bucket_arn" {
  description = "ARN of the Bronze layer S3 bucket"
  value       = aws_s3_bucket.bronze.arn
}

output "silver_bucket_id" {
  description = "ID of the Silver layer S3 bucket"
  value       = aws_s3_bucket.silver.id
}

output "silver_bucket_arn" {
  description = "ARN of the Silver layer S3 bucket"
  value       = aws_s3_bucket.silver.arn
}

output "gold_bucket_id" {
  description = "ID of the Gold layer S3 bucket"
  value       = aws_s3_bucket.gold.id
}

output "gold_bucket_arn" {
  description = "ARN of the Gold layer S3 bucket"
  value       = aws_s3_bucket.gold.arn
}

output "regulatory_bucket_id" {
  description = "ID of the Regulatory Store S3 bucket"
  value       = aws_s3_bucket.regulatory_store.id
}

output "regulatory_bucket_arn" {
  description = "ARN of the Regulatory Store S3 bucket"
  value       = aws_s3_bucket.regulatory_store.arn
}

# ---------------------------------------------------------
# GLUE CATALOG DATABASE OUTPUTS
# ---------------------------------------------------------

output "bronze_database_name" {
  description = "Name of the Bronze layer Glue catalog database"
  value       = aws_glue_catalog_database.bronze.name
}

output "silver_database_name" {
  description = "Name of the Silver layer Glue catalog database"
  value       = aws_glue_catalog_database.silver.name
}

output "gold_database_name" {
  description = "Name of the Gold layer Glue catalog database"
  value       = aws_glue_catalog_database.gold.name
}

output "database_names" {
  description = "Map of layer to Glue catalog database name"
  value = {
    bronze = aws_glue_catalog_database.bronze.name
    silver = aws_glue_catalog_database.silver.name
    gold   = aws_glue_catalog_database.gold.name
  }
}

# ---------------------------------------------------------
# GLUE CATALOG TABLE OUTPUTS
# ---------------------------------------------------------

output "bronze_table_names" {
  description = "Map of Bronze layer table names"
  value = {
    market_data_raw = aws_glue_catalog_table.market_data_raw.name
  }
}

output "silver_table_names" {
  description = "Map of Silver layer table names"
  value = {
    market_data_silver = aws_glue_catalog_table.market_data_silver.name
  }
}


output "gold_table_names" {
  description = "Map of Gold layer table names"
  value = {
    daily_trade_summaries      = aws_glue_catalog_table.daily_trade_summaries.name
    client_portfolio_snapshots = aws_glue_catalog_table.client_portfolio_snapshots.name
    instrument_performance     = aws_glue_catalog_table.instrument_performance.name
    risk_exposure_aggregates   = aws_glue_catalog_table.risk_exposure_aggregates.name
  }
}

# ---------------------------------------------------------
# GLUE CRAWLER OUTPUTS
# ---------------------------------------------------------

output "crawler_names" {
  description = "Map of layer to Glue crawler names"
  value = {
    bronze = aws_glue_crawler.bronze_market_data.name
    silver = aws_glue_crawler.silver_market_data.name
    gold   = aws_glue_crawler.gold_datasets.name
  }
}

output "crawler_arns" {
  description = "Map of layer to Glue crawler ARNs"
  value = {
    bronze = aws_glue_crawler.bronze_market_data.arn
    silver = aws_glue_crawler.silver_market_data.arn
    gold   = aws_glue_crawler.gold_datasets.arn
  }
}

# ---------------------------------------------------------
# LAKE FORMATION OUTPUTS
# ---------------------------------------------------------

output "lake_formation_resource_arns" {
  description = "Map of layer to Lake Formation registered resource ARNs"
  value = {
    bronze = aws_lakeformation_resource.bronze.arn
    silver = aws_lakeformation_resource.silver.arn
    gold   = aws_lakeformation_resource.gold.arn
  }
}

output "pii_restricted_columns" {
  description = "List of PII columns restricted for non-privileged roles"
  value       = ["client_name", "ssn", "account_number"]
}


# ---------------------------------------------------------
# CONVENIENCE MAP OUTPUTS (from s3_buckets.tf)
# ---------------------------------------------------------

output "bucket_arns" {
  description = "Map of all data lake bucket ARNs by layer name"
  value = {
    bronze           = aws_s3_bucket.bronze.arn
    silver           = aws_s3_bucket.silver.arn
    gold             = aws_s3_bucket.gold.arn
    regulatory_store = aws_s3_bucket.regulatory_store.arn
  }
}

output "bucket_names" {
  description = "Map of all data lake bucket names by layer name"
  value = {
    bronze           = aws_s3_bucket.bronze.bucket
    silver           = aws_s3_bucket.silver.bucket
    gold             = aws_s3_bucket.gold.bucket
    regulatory_store = aws_s3_bucket.regulatory_store.bucket
  }
}

output "bucket_ids" {
  description = "Map of all data lake bucket IDs by layer name"
  value = {
    bronze           = aws_s3_bucket.bronze.id
    silver           = aws_s3_bucket.silver.id
    gold             = aws_s3_bucket.gold.id
    regulatory_store = aws_s3_bucket.regulatory_store.id
  }
}

# ---------------------------------------------------------
# ENCRYPTION METADATA OUTPUTS
# ---------------------------------------------------------

output "encryption_configuration" {
  description = "Map showing KMS key ARN used for each bucket's encryption"
  value = {
    bronze           = var.kms_confidential_key_arn
    silver           = var.kms_confidential_key_arn
    gold             = var.kms_confidential_key_arn
    regulatory_store = var.kms_restricted_key_arn
  }
}

# ---------------------------------------------------------
# OBJECT LOCK METADATA OUTPUTS
# ---------------------------------------------------------

output "object_lock_configuration" {
  description = "Map showing Object Lock mode and retention for applicable buckets"
  value = {
    bronze = {
      mode           = "GOVERNANCE"
      retention_days = var.bronze_object_lock_retention_days
    }
    regulatory_store = {
      mode            = "COMPLIANCE"
      retention_years = var.regulatory_retention_years
    }
  }
}

# ---------------------------------------------------------
# GLUE JOB OUTPUTS
# ---------------------------------------------------------

output "glue_job_bronze_to_silver_name" {
  description = "Name of the Bronze-to-Silver Glue ETL job"
  value       = aws_glue_job.bronze_to_silver.name
}

output "glue_job_bronze_to_silver_arn" {
  description = "ARN of the Bronze-to-Silver Glue ETL job"
  value       = aws_glue_job.bronze_to_silver.arn
}

output "glue_job_silver_to_gold_name" {
  description = "Name of the Silver-to-Gold Glue ETL job"
  value       = aws_glue_job.silver_to_gold.name
}

output "glue_job_silver_to_gold_arn" {
  description = "ARN of the Silver-to-Gold Glue ETL job"
  value       = aws_glue_job.silver_to_gold.arn
}

output "glue_job_names" {
  description = "Map of ETL pipeline stage to Glue job name"
  value = {
    bronze_to_silver = aws_glue_job.bronze_to_silver.name
    silver_to_gold   = aws_glue_job.silver_to_gold.name
  }
}

output "glue_security_configuration_name" {
  description = "Name of the Glue security configuration (KMS encryption)"
  value       = aws_glue_security_configuration.etl_security.name
}

output "glue_connection_name" {
  description = "Name of the Glue VPC connection"
  value       = aws_glue_connection.vpc_connection.name
}

output "glue_scripts_bucket_id" {
  description = "ID of the S3 bucket for Glue job scripts"
  value       = aws_s3_bucket.glue_scripts.id
}

output "glue_scripts_bucket_arn" {
  description = "ARN of the S3 bucket for Glue job scripts"
  value       = aws_s3_bucket.glue_scripts.arn
}

# ---------------------------------------------------------
# PARTITION STRUCTURE OUTPUT
# ---------------------------------------------------------

output "hive_partition_structure" {
  description = "Hive-style partition key structure used in Bronze layer"
  value       = local.hive_partition_structure
}
