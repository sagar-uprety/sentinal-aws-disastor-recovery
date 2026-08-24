provider "aws" {
  region = local.region
  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "secondary"
    }
  }
}

# Alias for the primary region, so secondary can read primary's live ECS/RDS/ALB state.
# SSM reads use the default provider instead: primary's root already wrote local copies here.
provider "aws" {
  alias  = "primary"
  region = local.cfg.regions.primary
}
