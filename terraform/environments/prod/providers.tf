provider "aws" {
  region = "eu-west-1"
  alias  = "dr"

  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "dr"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "prod"
    }
  }
}
