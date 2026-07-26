data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_route53_zone" "sentinel" {
  name         = "sentinel.sagaruprety.com.np."
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

resource "aws_acm_certificate" "main" {
  domain_name       = local.app_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.main.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.sentinel.zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

module "alb" {
  source = "../../modules/alb"

  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn
  environment       = local.environment
  project_name      = local.project_name
  public_subnet_ids = module.vpc.public_subnet_ids
  vpc_id            = module.vpc.vpc_id
}

resource "aws_dynamodb_table" "checks" {
  #checkov:skip=CKV_AWS_119:the AWS-managed DynamoDB KMS key avoids customer-managed-key fixed cost for this low-volume portfolio monitor
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
  source = "../../modules/monitor-service"

  alb_security_group_id = module.alb.security_group_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  deploy_service        = var.deploy_service
  desired_count         = 1
  environment           = local.environment
  image_uri             = var.deploy_service ? "${module.ecr.repository_url}@${var.image_digest}" : "skip"
  project_name          = local.project_name
  target_group_arn      = module.alb.target_group_arn
  vpc_id                = module.vpc.vpc_id

  dynamodb_table_arn  = aws_dynamodb_table.checks.arn
  dynamodb_table_name = aws_dynamodb_table.checks.name
  monitored_url       = "https://app.${local.app_hostname}/healthz"

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
  zone_id         = data.aws_route53_zone.sentinel.zone_id
  name            = local.app_hostname
  type            = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }

  depends_on = [module.service]
}

resource "aws_iam_role" "github_actions" {
  name = "${local.project_name}-${local.environment}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:environment:production"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  #checkov:skip=CKV_AWS_290,CKV_AWS_355:ecr:GetAuthorizationToken and ECS task-definition registration/read do not support resource-level constraints
  name = "${local.project_name}-${local.environment}-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushMonitorImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = module.ecr.repository_arn
      },
      {
        Sid    = "MonitorTaskDefinitions"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
      },
      {
        Sid    = "DeployMonitorService"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = [
          module.service.cluster_arn,
          "arn:aws:ecs:${local.region}:${data.aws_caller_identity.current.account_id}:service/${local.project_name}-${local.environment}/${local.project_name}-${local.environment}",
        ]
      },
      {
        Sid    = "PassMonitorRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          module.service.task_execution_role_arn,
          module.service.task_role_arn,
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}
