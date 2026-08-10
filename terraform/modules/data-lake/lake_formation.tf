# Lake Formation - Data Governance and Column-Level Access Controls
# VerticalBroker AWS Data Engineering Platform
# Requirements: 2.4 (Register objects in Glue Data Catalog)
# Requirements: 14.3 (Least-privilege access)
# Requirements: 14.7 (PII masking and column-level security)
# Requirements: 3.2 (Schema enforcement via catalog)

# ---------------------------------------------------------
# LAKE FORMATION DATA LAKE SETTINGS
# ---------------------------------------------------------

resource "aws_lakeformation_data_lake_settings" "main" {
  admins = var.lake_formation_admin_arns

  create_database_default_permissions {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }

  create_table_default_permissions {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }
}

# ---------------------------------------------------------
# REGISTER S3 LOCATIONS WITH LAKE FORMATION
# ---------------------------------------------------------

resource "aws_lakeformation_resource" "bronze" {
  arn      = aws_s3_bucket.bronze.arn
  role_arn = var.lake_formation_service_role_arn
}

resource "aws_lakeformation_resource" "silver" {
  arn      = aws_s3_bucket.silver.arn
  role_arn = var.lake_formation_service_role_arn
}

resource "aws_lakeformation_resource" "gold" {
  arn      = aws_s3_bucket.gold.arn
  role_arn = var.lake_formation_service_role_arn
}


# ---------------------------------------------------------
# DATABASE-LEVEL PERMISSIONS: ETL Glue Role
# Full access to all databases and tables for ETL processing
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "etl_glue_bronze_db" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "CREATE_TABLE", "ALTER", "DROP", "DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.bronze.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_silver_db" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "CREATE_TABLE", "ALTER", "DROP", "DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.silver.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_gold_db" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "CREATE_TABLE", "ALTER", "DROP", "DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.gold.name
    catalog_id = var.aws_account_id
  }
}

# ETL Glue Role: Full table access on all tables in all databases
resource "aws_lakeformation_permissions" "etl_glue_bronze_tables" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "SELECT", "INSERT", "DELETE", "DESCRIBE", "ALTER"]

  table {
    database_name = aws_glue_catalog_database.bronze.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_silver_tables" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "SELECT", "INSERT", "DELETE", "DESCRIBE", "ALTER"]

  table {
    database_name = aws_glue_catalog_database.silver.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_gold_tables" {
  principal   = var.etl_glue_role_arn
  permissions = ["ALL", "SELECT", "INSERT", "DELETE", "DESCRIBE", "ALTER"]

  table {
    database_name = aws_glue_catalog_database.gold.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}


# ---------------------------------------------------------
# DATABASE-LEVEL PERMISSIONS: Market Data Lambda Role
# Create partition on bronze only (for ingestion)
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "market_data_lambda_bronze_db" {
  principal   = var.market_data_lambda_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.bronze.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "market_data_lambda_bronze_tables" {
  principal   = var.market_data_lambda_role_arn
  permissions = ["SELECT", "INSERT", "ALTER", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.bronze.name
    name          = aws_glue_catalog_table.market_data_raw.name
    catalog_id    = var.aws_account_id
  }
}

# ---------------------------------------------------------
# DATABASE-LEVEL PERMISSIONS: Analyst Role
# SELECT on silver and gold (no PII columns)
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "analyst_silver_db" {
  principal   = var.analyst_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.silver.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "analyst_gold_db" {
  principal   = var.analyst_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.gold.name
    catalog_id = var.aws_account_id
  }
}


# Analyst: SELECT on silver tables (all columns - no PII in silver)
resource "aws_lakeformation_permissions" "analyst_silver_tables" {
  principal   = var.analyst_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.silver.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

# Analyst: SELECT on gold daily_trade_summaries (no PII)
resource "aws_lakeformation_permissions" "analyst_gold_trade_summaries" {
  principal   = var.analyst_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.gold.name
    name          = aws_glue_catalog_table.daily_trade_summaries.name
    catalog_id    = var.aws_account_id
  }
}

# Analyst: SELECT on gold instrument_performance (no PII)
resource "aws_lakeformation_permissions" "analyst_gold_instrument_performance" {
  principal   = var.analyst_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.gold.name
    name          = aws_glue_catalog_table.instrument_performance.name
    catalog_id    = var.aws_account_id
  }
}

# Analyst: SELECT on gold risk_exposure_aggregates (no PII)
resource "aws_lakeformation_permissions" "analyst_gold_risk_exposure" {
  principal   = var.analyst_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.gold.name
    name          = aws_glue_catalog_table.risk_exposure_aggregates.name
    catalog_id    = var.aws_account_id
  }
}


# ---------------------------------------------------------
# COLUMN-LEVEL SECURITY: Restrict PII columns for Analyst role
# Deny access to client_name, ssn, account_number columns
# on client_portfolio_snapshots table
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "analyst_gold_portfolio_column_level" {
  principal   = var.analyst_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table_with_columns {
    database_name = aws_glue_catalog_database.gold.name
    name          = aws_glue_catalog_table.client_portfolio_snapshots.name
    catalog_id    = var.aws_account_id

    # Grant access to all columns EXCEPT PII columns
    excluded_column_names = [
      "client_name",
      "ssn",
      "account_number"
    ]
  }
}

# ---------------------------------------------------------
# COLUMN-LEVEL SECURITY: Compliance Role (full PII access)
# Compliance analysts need access to PII for regulatory reporting
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "compliance_gold_db" {
  principal   = var.compliance_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.gold.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "compliance_silver_db" {
  principal   = var.compliance_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.silver.name
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "compliance_bronze_db" {
  principal   = var.compliance_role_arn
  permissions = ["DESCRIBE"]

  database {
    name       = aws_glue_catalog_database.bronze.name
    catalog_id = var.aws_account_id
  }
}


# Compliance role: Full SELECT on all gold tables including PII columns
resource "aws_lakeformation_permissions" "compliance_gold_tables" {
  principal   = var.compliance_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.gold.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

# Compliance role: Full SELECT on all silver tables
resource "aws_lakeformation_permissions" "compliance_silver_tables" {
  principal   = var.compliance_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.silver.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

# Compliance role: Full SELECT on all bronze tables
resource "aws_lakeformation_permissions" "compliance_bronze_tables" {
  principal   = var.compliance_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.bronze.name
    wildcard      = true
    catalog_id    = var.aws_account_id
  }
}

# ---------------------------------------------------------
# DATA LOCATION PERMISSIONS
# Required for roles to access underlying S3 data via Lake Formation
# ---------------------------------------------------------

resource "aws_lakeformation_permissions" "etl_glue_bronze_location" {
  principal   = var.etl_glue_role_arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn        = aws_lakeformation_resource.bronze.arn
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_silver_location" {
  principal   = var.etl_glue_role_arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn        = aws_lakeformation_resource.silver.arn
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "etl_glue_gold_location" {
  principal   = var.etl_glue_role_arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn        = aws_lakeformation_resource.gold.arn
    catalog_id = var.aws_account_id
  }
}

resource "aws_lakeformation_permissions" "market_data_lambda_bronze_location" {
  principal   = var.market_data_lambda_role_arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn        = aws_lakeformation_resource.bronze.arn
    catalog_id = var.aws_account_id
  }
}
