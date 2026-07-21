resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-${var.environment}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
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

resource "aws_iam_role_policy" "app_deploy" {
  #checkov:skip=CKV_AWS_290,CKV_AWS_355:ecr:GetAuthorizationToken and ecs:RegisterTaskDefinition do not support resource-level scoping, per Hard Rule 7
  name = "${var.project_name}-${var.environment}-github-actions-deploy"
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
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [var.ecr_repository_arn]
      },
      {
        # RegisterTaskDefinition and DescribeTaskDefinition do not support resource-level
        # scoping to a specific family/revision at register time, per Hard Rule 7.
        Sid      = "EcsTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid    = "EcsDeploy"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = [
          var.ecs_cluster_arn,
          var.ecs_service_arn,
        ]
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [var.ecs_task_execution_role_arn, var.ecs_task_role_arn]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
      {
        Sid      = "WriteDeployedImageDigest"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = [var.deployed_image_digest_ssm_arn]
      },
    ]
  })
}
