locals {
  project_name = "sentinel-aws-dr"
  environment  = "prod"
  azs          = ["eu-central-1a", "eu-central-1b"]
  vpc_cidr     = "10.0.0.0/24"
}
