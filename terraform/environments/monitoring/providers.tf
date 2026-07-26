provider "aws" {
  region = local.region

  default_tags {
    tags = {
      Environment = local.environment
      ManagedBy   = "terraform"
      Project     = local.project_name
    }
  }
}
