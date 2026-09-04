terraform {
  required_version = ">= 1.5.7, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  profile             = "personal-cloud-admin"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Environment = "personal"
      ManagedBy   = "terraform"
      Project     = "personal-cloud"
    }
  }
}
