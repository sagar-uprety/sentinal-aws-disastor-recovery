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
  region = "eu-central-1"
  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "shared"
    }
  }
}
