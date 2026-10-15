###############################################################################
# providers.tf — AWS provider + remote state backend (Dev environment)
#
# Beginner notes:
# - The "terraform" block pins versions so everyone on the team uses the same ones.
# - The "backend" stores state remotely in S3 with a DynamoDB lock, so two people
#   don't apply at the same time. Create that bucket/table ONCE before `init`
#   (or comment the backend out to use local state while experimenting).
# - The "provider" block tells Terraform which AWS account/region to deploy into.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60" # Bedrock Agents + AOSS resources require a recent AWS provider
    }
  }

  # Remote state. Comment this whole block out to use local state while learning.
  backend "s3" {
    bucket         = "sparks-ai-tfstate-dev"      # pre-create this bucket
    key            = "ai-search/dev/terraform.tfstate"
    dynamodb_table = "sparks-ai-tflock-dev"       # pre-create this table (LockID: string)
    encrypt        = true
    # region is taken from -backend-config or AWS_REGION at `init` time
  }
}

provider "aws" {
  region = var.aws_region

  # Tag EVERYTHING so cost/ownership is traceable (important for the NO-COST gate + budgets).
  default_tags {
    tags = {
      Project    = "SPARKS-AI-Search"
      Env        = var.env
      ManagedBy  = "Terraform"
      CostCenter = var.cost_center
      Jira       = "SB-6562"
    }
  }
}
