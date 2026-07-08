provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = {
      Project     = "sentinel-aws-dr"
      ManagedBy   = "terraform"
      Environment = "prod"
    }
  }
}
