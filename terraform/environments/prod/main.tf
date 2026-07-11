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
  image_uri           = var.deploy_service ? "926883320788.dkr.ecr.eu-central-1.amazonaws.com/sentinel-aws-dr-prod@sha256:985b3b7bf3f39fddabc7e9f02ea3bca8343163fdbd587f5532fe924d6ae98cc0" : "skip"
  db_endpoint         = var.deploy_service ? "sentinel-aws-dr-prod.cvo2k4yamipe.eu-central-1.rds.amazonaws.com:5432" : "skip"
  db_name             = "sentinel"
  db_user             = "sentinel"
  db_password_ssm_arn = aws_ssm_parameter.database_password_prod.arn

  deploy_service = var.deploy_service
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

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "ssm_prod" {
  description         = "CMK for ${local.project_name} prod SSM SecureString parameters."
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${local.project_name}-prod-ssm-key"
  }
}

resource "aws_kms_key" "ssm_dr" {
  provider = aws.dr

  description         = "CMK for ${local.project_name} DR SSM SecureString parameters."
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${local.project_name}-dr-ssm-key"
  }
}

resource "aws_ssm_parameter" "database_password_prod" {
  name        = "/${local.project_name}/prod/database/password"
  description = "RDS master password for prod"
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.ssm_prod.arn

  value_wo         = random_password.database.result
  value_wo_version = var.credential_version
}

resource "aws_ssm_parameter" "database_password_dr" {
  provider = aws.dr

  name        = "/${local.project_name}/prod/database/password"
  description = "RDS master password for DR"
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.ssm_dr.arn

  value_wo         = random_password.database.result
  value_wo_version = var.credential_version
}
