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

provider "aws" {
  alias  = "prod"
  region = "eu-central-1"

  default_tags {
    tags = {
      Environment = "prod"
      ManagedBy   = "terraform"
      Project     = local.project_name
    }
  }
}
