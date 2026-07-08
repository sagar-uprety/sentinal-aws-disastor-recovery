provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Project     = "sentinel-aws-dr"
      ManagedBy   = "terraform"
      Environment = "dr"
    }
  }
}
