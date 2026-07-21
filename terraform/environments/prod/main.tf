data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = "18"
  latest  = true
}

data "aws_kms_key" "rds_primary" {
  key_id = "alias/aws/rds"
}

ephemeral "random_password" "database" {
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

# Replicates every image push to eu-west-1 under the same repository name and
# digest, so the DR environment can deploy from a local pull instead of
# depending on eu-central-1 being reachable during a regional incident.
resource "aws_ecr_replication_configuration" "main" {
  replication_configuration {
    rule {
      destination {
        region      = "eu-west-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
    }
  }
}

module "alb" {
  source = "../../modules/alb"

  project_name      = local.project_name
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = aws_acm_certificate_validation.primary.certificate_arn
}

module "ecs" {
  source = "../../modules/ecs-service"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn

  # Set var.image_digest to the immutable digest pushed to ECR in phase 2.
  image_uri              = var.deploy_service ? "${module.ecr.repository_url}@${var.image_digest}" : "skip"
  db_endpoint            = var.deploy_service ? module.rds.endpoint : "skip"
  db_name                = "sentinel"
  db_user                = "sentinel"
  db_instance_identifier = "${local.project_name}-${local.environment}"
  db_password_ssm_arn    = aws_ssm_parameter.database_password_prod.arn

  deploy_service = var.deploy_service
  desired_count  = var.desired_count
}

module "monitoring" {
  source = "../../modules/monitoring"

  project_name            = local.project_name
  environment             = local.environment
  ecs_cluster_name        = module.ecs.cluster_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_desired_count       = 2
  alert_email             = var.alert_email
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  project_name             = local.project_name
  environment              = local.environment
  github_org               = var.github_org
  github_repo              = var.github_repo
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  ecr_repository_arn = module.ecr.repository_arn
  ecs_cluster_arn    = module.ecs.cluster_arn
  # Constructed rather than referenced because the service only exists when deploy_service is true.
  ecs_service_arn             = "arn:aws:ecs:eu-central-1:${data.aws_caller_identity.current.account_id}:service/${local.project_name}-${local.environment}/${local.project_name}-${local.environment}"
  ecs_task_execution_role_arn = module.ecs.task_execution_role_arn
  ecs_task_role_arn           = module.ecs.task_role_arn

  deployed_image_digest_ssm_arn = aws_ssm_parameter.deployed_image_digest.arn
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

  replicate_source_db_arn = var.replicate_source_db_arn
  kms_key_id              = var.replicate_source_db_arn == null ? null : data.aws_kms_key.rds_primary.arn

  password_wo         = ephemeral.random_password.database.result
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

  value_wo         = ephemeral.random_password.database.result
  value_wo_version = var.credential_version
}

# Source of truth for the currently deployed image digest. The CI/CD pipeline
# (app.yml) writes the digest after every deploy; DR reads it to deploy the
# same image. Terraform only creates the parameter — it does not update the
# value after initial creation.
resource "aws_ssm_parameter" "deployed_image_digest" {
  #checkov:skip=CKV_AWS_337:uses the AWS-managed alias/aws/ssm key
  #checkov:skip=CKV2_AWS_34:non-secret image digest does not require encryption
  name        = "/${local.project_name}/prod/deployed-image-digest"
  description = "ECR image digest currently deployed to prod, updated by the CI/CD pipeline"
  type        = "String"
  tier        = "Standard"

  # Initial placeholder; overwritten by app.yml via aws ssm put-parameter.
  value = var.image_digest

  # CI/CD owns this value after initial creation — Terraform must not revert it.
  lifecycle {
    ignore_changes = [value]
  }
}

# AWS-managed key, not a customer-managed key: no per-key monthly fee, matches
# the pattern already used for SSM and Performance Insights encryption below.
data "aws_kms_key" "rds_dr" {
  provider = aws.dr
  key_id   = "alias/aws/rds"
}

resource "aws_db_instance_automated_backups_replication" "dr" {
  provider = aws.dr

  source_db_instance_arn = module.rds.arn
  kms_key_id             = data.aws_kms_key.rds_dr.arn
  retention_period       = 7
}

resource "aws_ssm_parameter" "database_password_dr" {
  #checkov:skip=CKV_AWS_337:uses the AWS-managed alias/aws/ssm key (no per-key monthly fee) rather than a customer-managed key
  provider = aws.dr

  name        = "/${local.project_name}/prod/database/password"
  description = "RDS master password for DR"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = ephemeral.random_password.database.result
  value_wo_version = var.credential_version
}
