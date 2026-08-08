# DR environment composes the same modules as prod, at pilot-light scale
# (ECS desired_count 0, single-AZ replica) until an operator promotes it.
# Prod dependencies are resolved through AWS data sources (not remote state)
# so DR plans and applies do not require prod's state file.

data "aws_caller_identity" "current" {}

# ECS service pointer is the source of truth for the image promoted to prod.
data "aws_ecs_service" "prod" {
  provider = aws.prod

  cluster_arn  = "arn:aws:ecs:eu-central-1:${data.aws_caller_identity.current.account_id}:cluster/${local.project_name}-prod"
  service_name = "${local.project_name}-prod"
}

data "aws_ecs_task_definition" "prod" {
  provider        = aws.prod
  task_definition = data.aws_ecs_service.prod.task_definition
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

# Prod resources discovered from AWS APIs — no remote-state dependency.
data "aws_db_instance" "prod" {
  provider               = aws.prod
  db_instance_identifier = "${local.project_name}-prod"
}

data "aws_lb" "prod" {
  provider = aws.prod
  name     = "${local.project_name}-prod-alb"
}

data "aws_ssm_parameter" "database_password_dr" {
  name = "/${local.project_name}/prod/database/password"
}

data "aws_ssm_parameter" "link_create_token_dr" {
  name = "/${local.project_name}/prod/link-create-token"
}

# Guards against creating a replica on a minor version that has drifted from
# prod; M4 requires the two regions resolve to the same PostgreSQL 18 minor
# before replica creation, not just "some" PostgreSQL 18.
check "engine_version_matches_prod" {
  assert {
    condition     = data.aws_rds_engine_version.postgres.version == data.aws_db_instance.prod.engine_version
    error_message = "eu-west-1's latest PostgreSQL 18 minor (${data.aws_rds_engine_version.postgres.version}) does not match prod's running version (${data.aws_db_instance.prod.engine_version}); resolve before creating the replica."
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
  certificate_arn   = aws_acm_certificate_validation.dr.certificate_arn
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
  image_uri                 = "${local.ecr_repository_url}@${local.prod_image_digest}"
  db_endpoint               = module.rds.endpoint
  db_name                   = "pilotlight"
  db_user                   = "pilotlight"
  db_password_ssm_arn       = data.aws_ssm_parameter.database_password_dr.arn
  link_create_token_ssm_arn = data.aws_ssm_parameter.link_create_token_dr.arn

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
  instance_class = data.aws_db_instance.prod.db_instance_class
  multi_az       = var.multi_az

  replicate_source_db_arn = data.aws_db_instance.prod.db_instance_arn
  kms_key_id              = data.aws_kms_key.rds.arn

  db_name  = "pilotlight"
  username = "pilotlight"
}

# ECR replication (configured in the prod environment) mirrors the
# repository into this region under the same account and name.
data "aws_ecr_repository" "app" {
  name = "${local.project_name}-prod"
}

locals {
  ecr_repository_url = data.aws_ecr_repository.app.repository_url
  prod_container     = one([for container in jsondecode(nonsensitive(data.aws_ecs_task_definition.prod.container_definitions)) : container if container.name == "shortener"])
  prod_image_digest  = split("@", local.prod_container.image)[1]
}
