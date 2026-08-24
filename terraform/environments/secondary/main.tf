data "aws_caller_identity" "current" {}

data "aws_route53_zone" "pilotlight" {
  name         = "${local.base_domain}."
  private_zone = false
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ECS service pointer is the source of truth for the image promoted to primary.
data "aws_ecs_service" "primary" {
  provider = aws.primary

  cluster_arn  = "arn:aws:ecs:eu-central-1:${local.account_id}:cluster/${local.project_name}-primary"
  service_name = "${local.project_name}-primary"
}

data "aws_ecs_task_definition" "primary" {
  provider        = aws.primary
  task_definition = data.aws_ecs_service.primary.task_definition
}

data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = "18"
  latest  = true
}

data "aws_kms_key" "rds" {
  key_id = "alias/aws/rds"
}

data "aws_db_instance" "primary" {
  provider               = aws.primary
  db_instance_identifier = "${local.project_name}-primary"
}

data "aws_lb" "primary" {
  provider = aws.primary
  name     = "${local.project_name}-primary-alb"
}

data "aws_ssm_parameter" "database_password_secondary" {
  name = "/${local.project_name}/primary/database/password"
}

data "aws_ssm_parameter" "link_create_token_secondary" {
  name = "/${local.project_name}/primary/link-create-token"
}

# guards against creating a replica on a minor version that has drifted from primary
check "engine_version_matches_primary" {
  assert {
    condition = data.aws_rds_engine_version.postgres.version == data.aws_db_instance.primary.engine_version
    error_message = format(
      "eu-west-1's latest Postgres minor (%s) does not match primary's version (%s); resolve before creating replica.",
      data.aws_rds_engine_version.postgres.version,
      data.aws_db_instance.primary.engine_version,
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

  # ACM reuses the account-level validation CNAME already managed by primary.
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

  # Same repository name and digest as primary; ECR replication (configured in
  # the primary environment) mirrors the image into this region.
  image_uri                 = "${local.ecr_repository_url}@${local.primary_image_digest}"
  db_endpoint               = module.rds.endpoint
  db_name                   = "pilotlight"
  db_user                   = "pilotlight"
  db_password_ssm_arn       = data.aws_ssm_parameter.database_password_secondary.arn
  link_create_token_ssm_arn = data.aws_ssm_parameter.link_create_token_secondary.arn

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
  instance_class = data.aws_db_instance.primary.db_instance_class
  multi_az       = var.multi_az

  replicate_source_db_arn = data.aws_db_instance.primary.db_instance_arn
  kms_key_id              = data.aws_kms_key.rds.arn

  db_name  = "pilotlight"
  username = "pilotlight"
}

# ECR replication (configured in the primary environment) mirrors the
# repository into this region under the same account and name.
data "aws_ecr_repository" "app" {
  name = "${local.project_name}-primary"
}

# The digest is pulled from primary's live task definition JSON rather than a
# Terraform output, since secondary deliberately has no remote-state dependency on primary.
locals {
  ecr_repository_url = data.aws_ecr_repository.app.repository_url
  # ecs-url-shortener's task definition always defines exactly one container, so no name match is needed here.
  primary_container    = one(jsondecode(nonsensitive(data.aws_ecs_task_definition.primary.container_definitions)))
  primary_image_digest = split("@", local.primary_container.image)[1]
}

# Detection-only HTTP health checks for evidence and alarming.
resource "aws_route53_health_check" "primary_detection" {
  type              = "HTTP"
  fqdn              = data.aws_lb.primary.dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-primary-detection"
  }
}

resource "aws_route53_health_check" "secondary_detection" {
  type              = "HTTP"
  fqdn              = module.alb.alb_dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-secondary-detection"
  }
}
