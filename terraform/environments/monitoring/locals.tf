locals {
  app_hostname      = "sentry.pilotlight.sagaruprety.com.np"
  workload_hostname = "shortener.pilotlight.sagaruprety.com.np"
  azs               = ["eu-north-1a", "eu-north-1b"]
  environment       = "monitoring"
  project_name      = "pilotlight"
  # separate from primary (eu-central-1) and secondary (eu-west-1) so a regional
  # incident in either drill region can't also take down the sentry.
  region   = "eu-north-1"
  vpc_cidr = "10.2.0.0/24"
  service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s-%s/%s-%s",
    local.region, data.aws_caller_identity.current.account_id,
    local.project_name, local.environment, local.project_name, local.environment,
  )
}
