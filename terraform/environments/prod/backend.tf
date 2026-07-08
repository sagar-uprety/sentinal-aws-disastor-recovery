terraform {
  backend "s3" {
    bucket         = "sentinel-terraform-state-CHANGEME"
    key            = "prod/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "sentinel-terraform-lock"
    encrypt        = true
  }
}
