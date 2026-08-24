# Route53 Recovery Control Config's control plane (cluster, control panel, routing controls,
# safety rules) only exists in us-west-2, regardless of where the application regions run.
provider "aws" {
  region = local.cfg.regions.arc
  default_tags {
    tags = {
      Project     = local.project_name
      ManagedBy   = "terraform"
      Environment = "arc"
    }
  }
}

provider "aws" {
  alias  = "primary"
  region = local.cfg.regions.primary
}

provider "aws" {
  alias  = "secondary"
  region = local.cfg.regions.secondary
}
