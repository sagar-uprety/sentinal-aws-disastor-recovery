provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Project     = "pilotlight"
      ManagedBy   = "terraform"
      Environment = "dr"
    }
  }
}

# Alias for the prod region, lets DR read prod's live ECS/RDS/ALB state directly
# (image digest, engine version, instance class, ALB DNS). SSM reads use the
# default eu-west-1 provider instead -- prod's own root already wrote the local
# copies there, so no cross-region SSM call happens.
provider "aws" {
  alias  = "prod"
  region = "eu-central-1"
}
