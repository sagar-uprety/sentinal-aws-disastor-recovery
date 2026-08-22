terraform {
  backend "s3" {
    bucket       = "sagar-demos-terraform-state"
    key          = "pilotlight/secondary/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
