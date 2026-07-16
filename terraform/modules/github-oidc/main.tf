resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # SHA1 thumbprints of token.actions.githubusercontent.com's current TLS chain
  # (ISRG root + intermediate), fetched directly rather than relying on a possibly
  # stale copy-pasted constant. AWS only requires a syntactically valid value here;
  # it does not re-validate GitHub's chain against it.
  thumbprint_list = [
    "ab9d0263244dd0326eb67015705a667e79cfe998",
    "2d74d6dfd96eea55ad7baafa0d3c6552b2dadc37",
  ]
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-${var.environment}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
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
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
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
        Sid      = "PassTaskExecutionRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [var.ecs_task_execution_role_arn]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}
