locals {
  # config.json is the one place project name, base domain, regions, and AZs are defined.
  cfg = jsondecode(file("${path.module}/../../../config.json"))

  project_name = local.cfg.project_name
  environment  = "primary"
  region       = local.cfg.regions.primary
  app_name     = local.cfg.apps.workload
  azs          = local.cfg.azs.primary
  vpc_cidr     = "10.0.0.0/24"
  account_id   = data.aws_caller_identity.current.account_id
  app_hostname = "shortener.${local.cfg.base_domain}"
  base_domain  = local.cfg.base_domain
}
