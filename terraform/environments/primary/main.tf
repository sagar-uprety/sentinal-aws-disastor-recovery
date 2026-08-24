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

data "aws_route53_zone" "pilotlight" {
  name         = "${local.base_domain}."
  private_zone = false
}

ephemeral "random_password" "database" {
  length  = 32 # characters
  special = false
}

ephemeral "random_password" "link_create_token" {
  length  = 48 # characters
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
  app_name     = local.app_name
}

# replicates every image push to the secondary region under the same repository name and
# digest, so the secondary environment can deploy from a local pull
resource "aws_ecr_replication_configuration" "main" {
  replication_configuration {
    rule {
      destination {
        region      = local.cfg.regions.secondary
        registry_id = data.aws_caller_identity.current.account_id
      }

      # scoping the repository name to just the primary image avoids replicating any other images
      # that might be pushed to the same account, e.g. from other projects or environments
      repository_filter {
        filter      = "${local.project_name}-${local.app_name}"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

module "acm_cert" {
  source = "../../modules/acm-cert"

  domain_name     = local.app_hostname
  route53_zone_id = data.aws_route53_zone.pilotlight.zone_id
}

module "alb" {
  source = "../../modules/alb"

  project_name      = local.project_name
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = module.acm_cert.certificate_arn
}

module "ecs" {
  source = "../../modules/ecs-url-shortener"

  project_name          = local.project_name
  environment           = local.environment
  vpc_id                = module.vpc.vpc_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn

  image_uri = (
    var.deploy_service
    ? "${module.ecr.repository_url}@${data.aws_ssm_parameter.image_digest[0].insecure_value}"
    : "skip"
  )
  db_endpoint               = var.deploy_service ? module.rds.endpoint : "skip"
  db_name                   = local.project_name
  db_user                   = local.project_name
  db_password_ssm_arn       = aws_ssm_parameter.database_password_primary.arn
  link_create_token_ssm_arn = aws_ssm_parameter.link_create_token_primary.arn

  deploy_service = var.deploy_service
  desired_count  = var.desired_count
}

# narrows the ALB's egress to just the ECS tasks' port
resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = module.alb.security_group_id
  referenced_security_group_id = module.ecs.security_group_id
  description                  = "App traffic to ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

module "monitoring" {
  source = "../../modules/alerting"

  project_name            = local.project_name
  environment             = local.environment
  ecs_cluster_name        = module.ecs.cluster_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_desired_count       = var.desired_count
  alert_email             = var.alert_email
}

module "github_oidc" {
  source = "../../modules/app-deploy-iam"

  project_name             = local.project_name
  environment              = local.environment
  github_org               = var.github_org
  github_repo              = var.github_repo
  github_owner_id          = var.github_owner_id
  github_repo_id           = var.github_repo_id
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  ecr_repository_arn         = module.ecr.repository_arn
  image_digest_parameter_arn = aws_ssm_parameter.image_digest.arn
  ecs_cluster_arn            = module.ecs.cluster_arn
  # Constructed rather than referenced because the service only exists when deploy_service is true.
  ecs_service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s-%s/%s-%s",
    local.region, local.account_id, local.project_name, local.environment, local.project_name, local.environment,
  )
  ecs_task_execution_role_arn = module.ecs.task_execution_role_arn
  ecs_task_role_arn           = module.ecs.task_role_arn

  secondary_ecs_cluster_arn = format(
    "arn:aws:ecs:%s:%s:cluster/%s-secondary",
    local.cfg.regions.secondary, local.account_id, local.project_name,
  )
  secondary_ecr_repository_arn = format(
    "arn:aws:ecr:%s:%s:repository/%s-%s",
    local.cfg.regions.secondary, local.account_id, local.project_name, local.app_name,
  )
  secondary_ecs_service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s-secondary/%s-secondary",
    local.cfg.regions.secondary, local.account_id, local.project_name, local.project_name,
  )
  secondary_ecs_task_execution_role_arn = format(
    "arn:aws:iam::%s:role/%s-secondary-ecs-task-exec",
    local.account_id, local.project_name,
  )
  secondary_ecs_task_role_arn = format(
    "arn:aws:iam::%s:role/%s-secondary-ecs-task",
    local.account_id, local.project_name,
  )
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

  db_name  = local.project_name
  username = local.project_name
}

# Terraform seeds this so the foundation phase can run before any image exists;
# ecs-url-shortener.yml overwrites it after each push, hence ignore_changes on value.
resource "aws_ssm_parameter" "image_digest" {
  name        = "/${local.project_name}/primary/image-digest"
  description = "Digest of the workload image ecs-url-shortener.yml last published to primary"
  type        = "String"
  tier        = "Standard"
  value       = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

# The resource attribute only holds the seeded value, so the live one is read back here.
data "aws_ssm_parameter" "image_digest" {
  count = var.deploy_service ? 1 : 0
  name  = aws_ssm_parameter.image_digest.name

  lifecycle {
    postcondition {
      condition     = can(regex("^sha256:[0-9a-f]{64}$", self.insecure_value))
      error_message = "No workload image published. Run ecs-url-shortener.yml publish-only before deploy_service=true."
    }
  }
}

resource "aws_ssm_parameter" "database_password_primary" {
  name        = "/${local.project_name}/primary/database/password"
  description = "RDS master password for primary"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = ephemeral.random_password.database.result
  value_wo_version = var.credential_version
}

resource "aws_ssm_parameter" "link_create_token_primary" {
  name        = "/${local.project_name}/primary/link-create-token"
  description = "URL-shortener operator token for primary"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = ephemeral.random_password.link_create_token.result
  value_wo_version = var.link_token_version
}

data "aws_kms_key" "rds_secondary" {
  provider = aws.secondary
  key_id   = "alias/aws/rds"
}

resource "aws_db_instance_automated_backups_replication" "secondary" {
  provider = aws.secondary

  source_db_instance_arn = module.rds.arn
  kms_key_id             = data.aws_kms_key.rds_secondary.arn
  retention_period       = 7 # days
}

# Primary's state owns the secondary-region SSM parameters so they exist ahead of any failover:
# the promoted replica inherits primary's password and must resolve a value already in place.
resource "aws_ssm_parameter" "database_password_secondary" {
  provider = aws.secondary

  name        = "/${local.project_name}/primary/database/password"
  description = "RDS master password for secondary"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = ephemeral.random_password.database.result
  value_wo_version = var.credential_version
}

resource "aws_ssm_parameter" "link_create_token_secondary" {
  provider = aws.secondary

  name        = "/${local.project_name}/primary/link-create-token"
  description = "URL-shortener operator token for secondary"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = ephemeral.random_password.link_create_token.result
  value_wo_version = var.link_token_version
}

# Simple A alias to primary's own ALB when ARC is inactive; .
resource "aws_route53_record" "workload" {
  count   = local.cfg.create_arc ? 0 : 1
  zone_id = data.aws_route53_zone.pilotlight.zone_id
  name    = local.app_hostname
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}
