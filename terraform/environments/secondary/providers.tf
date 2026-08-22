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

# Alias for the primary region, lets secondary read primary's live ECS/RDS/ALB state directly
# (image digest, engine version, instance class, ALB DNS). SSM reads use the
# default eu-west-1 provider instead -- primary's own root already wrote the local
# copies there, so no cross-region SSM call happens.
provider "aws" {
  alias  = "primary"
  region = "eu-central-1"
}
