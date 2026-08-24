locals {
  # config.json is the one place project name, base domain, regions, and AZs are defined.
  cfg = jsondecode(file("${path.module}/../../../config.json"))

  project_name = local.cfg.project_name
  environment  = "secondary"
  region       = local.cfg.regions.secondary
  app_name     = local.cfg.apps.workload
  azs          = local.cfg.azs.secondary
  vpc_cidr     = "10.1.0.0/24"
  app_hostname = "shortener.${local.cfg.base_domain}"
  base_domain  = local.cfg.base_domain
}
