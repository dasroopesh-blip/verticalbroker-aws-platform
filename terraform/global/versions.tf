# Global Resources - Terraform Version Constraints
# Resources deployed once at the Organization level (not per-environment)
# Examples: AWS Organizations, SCPs, Transit Gateway, shared DNS

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Global resources are deployed from the Management Account
  default_tags {
    tags = {
      Environment        = "global"
      Service            = "verticalbroker-platform"
      Owner              = "platform-engineering"
      CostCenter         = "DE-001"
      DataClassification = "Restricted"
      Compliance         = "FINRA-4511"
      ManagedBy          = "terraform"
    }
  }
}
