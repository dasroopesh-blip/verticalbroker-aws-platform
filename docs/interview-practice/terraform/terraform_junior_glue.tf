# =============================================================================
# JUNIOR DEVELOPER'S TERRAFORM — Glue ETL Infrastructure
# =============================================================================
# Contains multiple production-critical errors.
# =============================================================================

provider "aws" {
  region = "us-east-1"
}

# ERROR 1 (P1): No terraform block, no backend, no version pinning

# --- S3 Buckets ---
# ERROR 2 (P1): Single bucket for everything — no layer separation
# ERROR 3 (P0): No encryption on any bucket
# ERROR 4 (P1): No public access blocks
# ERROR 5 (P2): No lifecycle rules — data grows forever, cost explodes
resource "aws_s3_bucket" "data" {
  bucket = "verticalbroker-prod-data"
}

# --- Glue Database ---
# ERROR 6 (P2): Single database for all layers — no separation
resource "aws_glue_catalog_database" "trades" {
  name = "trades"
}

# --- Glue Job (ONE job for everything) ---
# ERROR 7 (P1): One monolithic job instead of Bronze/Silver/Gold separation
resource "aws_glue_job" "trade_etl" {
  name     = "trade-etl"
  role_arn = aws_iam_role.glue_role.arn

  command {
    name            = "glueetl"
    script_location = "s3://verticalbroker-prod-data/scripts/etl.py"
    python_version  = "3"
  }

  # ERROR 8 (P1): Only 2 DPU — will be extremely slow on production data
  # ERROR 9 (P2): No timeout — job could run forever (costs $$$)
  max_capacity = 2.0

  # ERROR 10 (P1): No Glue version specified — uses deprecated default
  # ERROR 11 (P2): No worker type specified (G.1X default is weakest)

  # ERROR 12 (P2): No default arguments / parameters
  # Job can't be parameterized for different dates or environments

  # ERROR 13 (P1): No job bookmarks — will reprocess same files every run
}

# --- IAM ---
resource "aws_iam_role" "glue_role" {
  name = "glue-etl-role"

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

# ERROR 14 (P0): Wildcard permissions — gives Glue access to EVERYTHING
resource "aws_iam_role_policy_attachment" "glue_full_access" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"  # YIKES!
}

# ERROR 15 (P0): No additional policies — just gives admin to a data job

# MISSING: No Glue trigger/schedule — job must be started manually
# MISSING: No CloudWatch alarms on job failures
# MISSING: No Glue crawler for schema detection
# MISSING: No Step Functions orchestration for Bronze→Silver→Gold ordering
# MISSING: No Glue Data Quality rules
# MISSING: No outputs
# MISSING: No tags
