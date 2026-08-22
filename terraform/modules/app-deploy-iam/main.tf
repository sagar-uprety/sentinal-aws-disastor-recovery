# per-environment app-deploy role: push an image and update one ECS service, nothing infrastructure-shaped.
# terraform-ci-iam is the separate, much broader role that runs terraform apply.
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
          # TODO: check alignment with github actions
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:environment:production"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "workload_deploy" {
  name = "${var.project_name}-${var.environment}-github-actions-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      # docker-login to ECR before any push.
      {
        Sid    = "EcrAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        # ecr:GetAuthorizationToken is account-scoped and takes no resource ARN.
        #checkov:skip=CKV_AWS_290,CKV_AWS_355
        Resource = "*"
      },
      # pushes the newly built image to this environment's own ECR repo.
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
      # publishes the digest Terraform reads back, so no image value travels as a workflow -var.
      {
        Sid      = "SsmPublishImageDigest"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = [var.image_digest_parameter_arn]
      },
      ],
      # confirms the image finished replicating to secondary's region before deploying there.
      var.secondary_ecr_repository_arn == null ? [] : [
        {
          Sid      = "EcrReadReplica"
          Effect   = "Allow"
          Action   = ["ecr:DescribeImages"]
          Resource = [var.secondary_ecr_repository_arn]
        },
      ],
      [
        # registers the new task-def revision pointing at the pushed image.
        {
          Sid    = "EcsTaskDefinitions"
          Effect = "Allow"
          Action = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
          # Task-definition actions do not support resource-level permissions.
          #checkov:skip=CKV_AWS_290,CKV_AWS_355
          Resource = "*"
        },
        # rolls the service onto the new revision (both primary and secondary, one pipeline).
        {
          Sid    = "EcsDeploy"
          Effect = "Allow"
          Action = [
            "ecs:DescribeServices",
            "ecs:UpdateService",
          ]
          Resource = compact([
            var.ecs_cluster_arn,
            var.ecs_service_arn,
            var.secondary_ecs_cluster_arn,
            var.secondary_ecs_service_arn,
          ])
        },
        # this limits role handoff to these four roles -- AWS checks it separately from
        # RegisterTaskDefinition above, which alone would let this pipeline name any role in the account.
        {
          Sid    = "PassTaskRoles"
          Effect = "Allow"
          Action = ["iam:PassRole"]
          Resource = compact([
            var.ecs_task_execution_role_arn,
            var.ecs_task_role_arn,
            var.secondary_ecs_task_execution_role_arn,
            var.secondary_ecs_task_role_arn,
          ])
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "ecs-tasks.amazonaws.com"
            }
          }
        },
    ])
  })
}
