# Terraform and Provider Version Constraints
# VerticalBroker AWS Data Engineering Platform
# Requirements: 13.1 (Terraform 1.5+ with AWS Provider 5.x)

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Random provider for unique naming
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }

    # Archive provider for Lambda packaging
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    # Null provider for provisioners and triggers
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ---------------------------------------------------------
# PRIMARY PROVIDER CONFIGURATION
# ---------------------------------------------------------

provider "aws" {
  region = var.aws_region

  # Mandatory tags applied to all resources (Requirement 13.5)
  default_tags {
    tags = local.default_tags
  }
}

# ---------------------------------------------------------
# DR REGION PROVIDER
# Used for cross-region replication resources
# Requirement 16.3: Replicate Gold_Layer data and Terraform state to secondary region
# ---------------------------------------------------------

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.default_tags
  }
}
