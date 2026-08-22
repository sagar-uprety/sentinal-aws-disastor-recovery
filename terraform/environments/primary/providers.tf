provider "aws" {
  region = "eu-west-1"
  alias  = "secondary"

  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "secondary"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "primary"
    }
  }
}
