locals {
  # config.json is the one place project name, base domain, regions, and AZs are defined.
  cfg = jsondecode(file("${path.module}/../../../config.json"))

  project_name = local.cfg.project_name
  environment  = "monitoring"
  # separate from primary and secondary so a regional incident in either drill region
  # can't also take down the sentry.
  region   = local.cfg.regions.monitoring
  azs      = local.cfg.azs.monitoring
  vpc_cidr = "10.2.0.0/24"

  base_domain       = local.cfg.base_domain
  app_hostname      = "sentry.${local.cfg.base_domain}"
  workload_hostname = "shortener.${local.cfg.base_domain}"

  service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s-%s/%s-%s",
    local.region, data.aws_caller_identity.current.account_id,
    local.project_name, local.environment, local.project_name, local.environment,
  )
}
