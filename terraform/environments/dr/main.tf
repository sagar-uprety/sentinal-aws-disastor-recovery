data "aws_caller_identity" "current" {}

data "aws_route53_zone" "pilotlight" {
  name         = "pilotlight.sagaruprety.com.np."
  private_zone = false
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ECS service pointer is the source of truth for the image promoted to prod.
data "aws_ecs_service" "prod" {
  provider = aws.prod

  cluster_arn  = "arn:aws:ecs:eu-central-1:${local.account_id}:cluster/${local.project_name}-prod"
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

data "aws_kms_key" "rds" {
  key_id = "alias/aws/rds"
}

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

# guards against creating a replica on a minor version that has drifted from prod
check "engine_version_matches_prod" {
  assert {
    condition = data.aws_rds_engine_version.postgres.version == data.aws_db_instance.prod.engine_version
    error_message = format(
      "eu-west-1's latest Postgres minor (%s) does not match prod's version (%s); resolve before creating replica.",
      data.aws_rds_engine_version.postgres.version,
      data.aws_db_instance.prod.engine_version,
    )
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name       = local.project_name
  environment        = local.environment
  vpc_cidr           = local.vpc_cidr
  availability_zones = local.azs

  create_s3_endpoint = true
}

module "acm_cert" {
  source = "../../modules/acm-cert"

  domain_name     = local.app_hostname
  route53_zone_id = data.aws_route53_zone.pilotlight.zone_id

  # ACM reuses the account-level validation CNAME already managed by prod.
  create_validation_records = false
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

# Narrows the ALB's egress to just the ECS tasks' port
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

# The digest is pulled from prod's live task definition JSON rather than a
# Terraform output, since DR deliberately has no remote-state dependency on prod.
locals {
  ecr_repository_url = data.aws_ecr_repository.app.repository_url
  # ecs-url-shortener's task definition always defines exactly one container, so no name match is needed here.
  prod_container    = one(jsondecode(nonsensitive(data.aws_ecs_task_definition.prod.container_definitions)))
  prod_image_digest = split("@", local.prod_container.image)[1]
}

# Detection-only HTTP health checks for evidence and alarming.
resource "aws_route53_health_check" "primary_detection" {
  type              = "HTTP"
  fqdn              = data.aws_lb.prod.dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-primary-detection"
  }
}

resource "aws_route53_health_check" "dr_detection" {
  type              = "HTTP"
  fqdn              = module.alb.alb_dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-dr-detection"
  }
}

module "route53_failover" {
  source = "../../modules/route53-failover"
  count  = var.create_arc ? 1 : 0

  project_name    = local.project_name
  route53_zone_id = data.aws_route53_zone.pilotlight.zone_id
  record_name     = local.app_hostname

  primary_alb_dns_name = data.aws_lb.prod.dns_name
  primary_alb_zone_id  = data.aws_lb.prod.zone_id

  dr_alb_dns_name = module.alb.alb_dns_name
  dr_alb_zone_id  = module.alb.alb_zone_id
}

# Simple A alias to prod when ARC is not provisioned. Must wait for the
# ARC module (and its failover records) to be destroyed first: Route53
# rejects a simple A record when set-identifier failover records exist
# with the same name and type.
resource "aws_route53_record" "workload" {
  count   = var.create_arc ? 0 : 1
  zone_id = data.aws_route53_zone.pilotlight.zone_id
  name    = local.app_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.prod.dns_name
    zone_id                = data.aws_lb.prod.zone_id
    evaluate_target_health = true
  }

  depends_on = [module.route53_failover]
}
