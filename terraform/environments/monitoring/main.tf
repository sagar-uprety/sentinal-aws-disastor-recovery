data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_route53_zone" "pilotlight" {
  name         = "pilotlight.sagaruprety.com.np."
  private_zone = false
}

module "vpc" {
  source = "../../modules/vpc"

  availability_zones = local.azs
  environment        = local.environment
  project_name       = local.project_name
  vpc_cidr           = local.vpc_cidr
}

module "ecr" {
  source = "../../modules/ecr"

  environment  = local.environment
  project_name = local.project_name
}

# Terraform seeds this so the foundation phase can run before any image exists;
# ecs-monitor.yml overwrites it after each push, hence ignore_changes on value.
resource "aws_ssm_parameter" "image_digest" {
  name        = "/${local.project_name}/${local.environment}/image-digest"
  description = "Digest of the monitor image ecs-monitor.yml last published"
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
      error_message = "No monitor image published yet. Run ecs-monitor.yml publish-only before deploy_service=true."
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

  certificate_arn   = module.acm_cert.certificate_arn
  environment       = local.environment
  project_name      = local.project_name
  public_subnet_ids = module.vpc.public_subnet_ids
  vpc_id            = module.vpc.vpc_id
}

resource "aws_dynamodb_table" "checks" {
  name         = "${local.project_name}-${local.environment}-checks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

module "service" {
  source = "../../modules/ecs-monitor"

  alb_security_group_id = module.alb.security_group_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  deploy_service        = var.deploy_service
  desired_count         = 1
  environment           = local.environment
  image_uri = (
    var.deploy_service
    ? "${module.ecr.repository_url}@${data.aws_ssm_parameter.image_digest[0].insecure_value}"
    : "skip"
  )
  project_name     = local.project_name
  target_group_arn = module.alb.target_group_arn
  vpc_id           = module.vpc.vpc_id

  dynamodb_table_arn  = aws_dynamodb_table.checks.arn
  dynamodb_table_name = aws_dynamodb_table.checks.name
  monitored_url       = "https://${local.workload_hostname}/healthz"

  prod_region              = "eu-central-1"
  prod_ecs_cluster         = "${local.project_name}-prod"
  prod_ecs_service         = "${local.project_name}-prod"
  prod_database_identifier = "${local.project_name}-prod"

  dr_region              = "eu-west-1"
  dr_ecs_cluster         = "${local.project_name}-dr"
  dr_ecs_service         = "${local.project_name}-dr"
  dr_database_identifier = "${local.project_name}-dr"
}

resource "aws_route53_record" "monitor" {
  count = var.deploy_service ? 1 : 0

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.pilotlight.zone_id
  name            = local.app_hostname
  type            = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }

  depends_on = [module.service]
}

module "github_oidc" {
  source = "../../modules/app-deploy-iam"

  project_name             = local.project_name
  environment              = local.environment
  github_org               = var.github_org
  github_repo              = var.github_repo
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  ecr_repository_arn          = module.ecr.repository_arn
  image_digest_parameter_arn  = aws_ssm_parameter.image_digest.arn
  ecs_cluster_arn             = module.service.cluster_arn
  ecs_service_arn             = local.service_arn
  ecs_task_execution_role_arn = module.service.task_execution_role_arn
  ecs_task_role_arn           = module.service.task_role_arn
}

module "alerting" {
  source = "../../modules/alerting"

  project_name            = local.project_name
  environment             = local.environment
  ecs_cluster_name        = module.service.cluster_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_desired_count       = var.deploy_service ? 1 : 0
  alert_email             = var.alert_email
  create_rds_alarms       = false
}
