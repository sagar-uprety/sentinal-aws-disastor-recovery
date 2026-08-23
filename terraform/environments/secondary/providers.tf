provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Project     = "pilotlight"
      ManagedBy   = "terraform"
      Environment = "secondary"
    }
  }
}

# Alias for the primary region, so secondary can read primary's live ECS/RDS/ALB state.
# SSM reads use the default provider instead: primary's root already wrote local copies here.
provider "aws" {
  alias  = "primary"
  region = "eu-central-1"
}
