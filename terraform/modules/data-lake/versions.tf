# Data Lake Module - Provider and Version Requirements
# VerticalBroker AWS Data Engineering Platform
#
# Declares required providers including the aws.dr alias for cross-region resources.
# Requirements: 13.1 (Terraform 1.5+ / AWS Provider 5.x)

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.dr]
    }
  }
}
