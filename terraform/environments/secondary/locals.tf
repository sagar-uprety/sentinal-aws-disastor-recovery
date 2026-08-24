locals {
  app_hostname = "shortener.${var.base_domain}"
  project_name = "pilotlight"
  environment  = "secondary"
  azs          = ["eu-west-1a", "eu-west-1b"]
  vpc_cidr     = "10.1.0.0/24"
}
