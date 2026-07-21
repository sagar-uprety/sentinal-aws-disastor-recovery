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

# Alias for the prod region — lets DR read prod SSM parameters cross-region.
provider "aws" {
  alias  = "prod"
  region = "eu-central-1"
}
