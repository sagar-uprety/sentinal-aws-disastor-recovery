data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = "18"
  latest  = true
}

resource "random_password" "database" {
  length  = 32
  special = false
}

module "vpc" {
  source = "../../modules/vpc"

  project_name       = local.project_name
  environment        = local.environment
  vpc_cidr           = local.vpc_cidr
  availability_zones = local.azs
}

module "ecr" {
  source = "../../modules/ecr"

  project_name = local.project_name
  environment  = local.environment
}

module "alb" {
  source = "../../modules/alb"

  project_name      = local.project_name
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
}

module "ecs" {
  source = "../../modules/ecs-service"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn

  # Replace with immutable image digest after pushing to ECR in phase 2.
  image_uri           = var.deploy_service ? "926883320788.dkr.ecr.eu-central-1.amazonaws.com/sentinel-aws-dr-prod@sha256:ea1e5b66fc916b0f5b921533bd19f7afa2cbea73721fda5e20bfcfa941e4d092" : "skip"
  db_endpoint         = var.deploy_service ? "sentinel-aws-dr-prod.cvo2k4yamipe.eu-central-1.rds.amazonaws.com:5432" : "skip"
  db_name             = "sentinel"
  db_user             = "sentinel"
  db_password_ssm_arn = aws_ssm_parameter.database_password_prod.arn
  otel_endpoint       = module.monitoring.otel_collector_endpoint

  deploy_service = var.deploy_service
}

module "monitoring" {
  source = "../../modules/monitoring"

  project_name            = local.project_name
  environment             = local.environment
  vpc_id                  = module.vpc.vpc_id
  app_subnet_ids          = module.vpc.app_subnet_ids
  ecs_cluster_name        = module.ecs.cluster_name
  app_security_group_id   = module.ecs.security_group_id
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_desired_count       = 2
  alert_email             = var.alert_email
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  project_name = local.project_name
  environment  = local.environment
  github_org   = var.github_org
  github_repo  = var.github_repo

  ecr_repository_arn          = module.ecr.repository_arn
  ecs_cluster_arn             = "arn:aws:ecs:eu-central-1:926883320788:cluster/${local.project_name}-${local.environment}"
  ecs_service_arn             = "arn:aws:ecs:eu-central-1:926883320788:service/${local.project_name}-${local.environment}/${local.project_name}-${local.environment}"
  ecs_task_execution_role_arn = module.ecs.task_execution_role_arn
}

module "rds" {
  source = "../../modules/rds"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.db_subnet_ids
  ecs_security_group_id = module.ecs.security_group_id

  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = "db.t4g.micro"
  multi_az       = var.multi_az

  password_wo         = random_password.database.result
  password_wo_version = var.credential_version

  db_name  = "sentinel"
  username = "sentinel"
}

resource "aws_ssm_parameter" "database_password_prod" {
  #checkov:skip=CKV_AWS_337:uses the AWS-managed alias/aws/ssm key (no per-key monthly fee) rather than a customer-managed key
  name        = "/${local.project_name}/prod/database/password"
  description = "RDS master password for prod"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = random_password.database.result
  value_wo_version = var.credential_version
}

resource "aws_ssm_parameter" "database_password_dr" {
  #checkov:skip=CKV_AWS_337:uses the AWS-managed alias/aws/ssm key (no per-key monthly fee) rather than a customer-managed key
  provider = aws.dr

  name        = "/${local.project_name}/prod/database/password"
  description = "RDS master password for DR"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = random_password.database.result
  value_wo_version = var.credential_version
}
