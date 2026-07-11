terraform {
  backend "s3" {
    bucket       = "sentinel-terraform-state-926883320788"
    key          = "dr/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
