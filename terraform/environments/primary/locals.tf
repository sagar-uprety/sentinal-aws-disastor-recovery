locals {
  project_name = "pilotlight"
  environment  = "primary"
  azs          = ["eu-central-1a", "eu-central-1b"]
  vpc_cidr     = "10.0.0.0/24"
  account_id   = data.aws_caller_identity.current.account_id
  app_hostname = "shortener.${var.base_domain}"
}
