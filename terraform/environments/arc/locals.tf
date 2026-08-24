locals {
  # config.json is the one place project name, base domain, regions, and the ARC toggle are defined.
  cfg = jsondecode(file("${path.module}/../../../config.json"))

  project_name = local.cfg.project_name
  base_domain  = local.cfg.base_domain
  app_hostname = "shortener.${local.cfg.base_domain}"
}
