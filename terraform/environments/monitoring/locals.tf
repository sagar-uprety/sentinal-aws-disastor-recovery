locals {
  app_hostname      = "monitor.pilotlight.sagaruprety.com.np"
  workload_hostname = "shortener.pilotlight.sagaruprety.com.np"
  azs               = ["eu-west-1a", "eu-west-1b"]
  environment       = "monitoring"
  project_name      = "pilotlight"
  region            = "eu-west-1"
  vpc_cidr          = "10.2.0.0/24"
}
