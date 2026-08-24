provider "aws" {
  region = local.cfg.regions.secondary
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
  region = local.region

  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "primary"
    }
  }
}
