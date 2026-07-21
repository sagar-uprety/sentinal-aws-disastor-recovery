# DR environment composes the same modules as prod, at pilot-light scale
# (ECS desired_count 0, single-AZ replica) until an operator promotes it.

data "terraform_remote_state" "prod" {
  backend = "s3"

  config = {
    bucket = "sagar-demos-terraform-state"
    key    = "sentinel/prod/terraform.tfstate"
    region = "eu-central-1"
  }
}

data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = "18"
  latest  = true
}

# AWS-managed key, not a customer-managed key: no per-key monthly fee, matches
# the pattern used for SSM and Performance Insights encryption elsewhere.
data "aws_kms_key" "rds" {
  key_id = "alias/aws/rds"
}

# Guards against creating a replica on a minor version that has drifted from
# prod; M4 requires the two regions resolve to the same PostgreSQL 18 minor
# before replica creation, not just "some" PostgreSQL 18.
check "engine_version_matches_prod" {
  assert {
    condition     = data.aws_rds_engine_version.postgres.version == data.terraform_remote_state.prod.outputs.rds_engine_version
    error_message = "eu-west-1's latest PostgreSQL 18 minor (${data.aws_rds_engine_version.postgres.version}) does not match prod's running version (${data.terraform_remote_state.prod.outputs.rds_engine_version}); resolve before creating the replica."
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name       = local.project_name
  environment        = local.environment
  vpc_cidr           = local.vpc_cidr
  availability_zones = local.azs

  create_s3_endpoint         = true
  create_interface_endpoints = false
}

module "alb" {
  source = "../../modules/alb"

  project_name      = local.project_name
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = data.terraform_remote_state.prod.outputs.dr_certificate_arn
}

module "ecs" {
  source = "../../modules/ecs-service"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn

  # Same repository name and digest as prod; ECR replication (configured in
  # the prod environment) mirrors the image into this region.
  image_uri              = "${local.ecr_repository_url}@${data.terraform_remote_state.prod.outputs.image_digest}"
  db_endpoint            = module.rds.endpoint
  db_name                = "sentinel"
  db_user                = "sentinel"
  db_instance_identifier = "${local.project_name}-${local.environment}"
  db_password_ssm_arn    = data.terraform_remote_state.prod.outputs.database_password_dr_ssm_arn

  deploy_service = true
  desired_count  = var.desired_count
}

module "monitoring" {
  source = "../../modules/monitoring"

  project_name            = local.project_name
  environment             = local.environment
  ecs_cluster_name        = module.ecs.cluster_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_desired_count       = var.desired_count
  alert_email             = var.alert_email
}

module "rds" {
  source = "../../modules/rds"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.db_subnet_ids
  ecs_security_group_id = module.ecs.security_group_id

  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = data.terraform_remote_state.prod.outputs.rds_instance_class
  multi_az       = var.multi_az

  replicate_source_db_arn = data.terraform_remote_state.prod.outputs.rds_instance_arn
  kms_key_id              = data.aws_kms_key.rds.arn

  db_name  = "sentinel"
  username = "sentinel"
}

locals {
  # ECR replication (configured in the prod environment) mirrors the
  # repository into this region under the same account and name.
  ecr_repository_url = replace(data.terraform_remote_state.prod.outputs.ecr_repository_url, "eu-central-1", "eu-west-1")
}
