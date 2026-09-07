# ---------------------------------------------------------------------------
# Terraform + provider version constraints.
#
# LEARNING NOTE: `terraform` blocks configure Terraform itself. Pinning
# versions keeps `terraform apply` reproducible across machines and over time.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # allow 5.x, block 6.x breaking changes
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5" # used to generate the DB password
    }
  }

  # For a real team you would store state remotely (S3 + DynamoDB lock) so the
  # team shares one state file. Left commented so `terraform init` works locally
  # out of the box. Uncomment and fill in to enable remote state.
  #
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "filings-assistant/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tflock-table"
  #   encrypt        = true
  # }
}
