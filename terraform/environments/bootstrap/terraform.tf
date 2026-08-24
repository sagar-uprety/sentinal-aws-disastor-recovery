terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = local.cfg.regions.primary
  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "shared"
    }
  }
}
