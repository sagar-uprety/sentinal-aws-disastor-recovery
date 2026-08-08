data "aws_caller_identity" "current" {}

# Transitional: trusts both the pre-rename and post-rename repo full-name
# during the GitHub repo rename window, since this repo is on legacy mutable
# OIDC sub claims (renamed after the token was minted, the sub value changes
# to match). Drop the old entry once the rename is confirmed and CI has
# authenticated successfully under the new name.
locals {
  github_repo_full_names = [
    "sagar-uprety/sentinal-aws-disastor-recovery",
    "${var.github_org}/${var.github_repo}",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]
}

# Persistent bootstrap breaks the from-zero deployment credential cycle.
resource "aws_iam_role" "terraform_github_actions" {
  name = "${var.project_name}-terraform-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [for repo in local.github_repo_full_names : "repo:${repo}:environment:terraform-production"]
        }
      }
    }]
  })
}

# Pull requests need read-only AWS and state access for speculative plans without entering the production environment.
resource "aws_iam_role" "terraform_github_plan" {
  name = "${var.project_name}-terraform-github-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [for repo in local.github_repo_full_names : "repo:${repo}:pull_request"]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_read_only" {
  role       = aws_iam_role.terraform_github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

moved {
  from = aws_iam_role_policy_attachment.terraform_plan_view_only
  to   = aws_iam_role_policy_attachment.terraform_plan_read_only
}

resource "aws_iam_role_policy" "terraform_plan_state" {
  name = "${var.project_name}-terraform-plan-state"
  role = aws_iam_role.terraform_github_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
      Resource = [aws_s3_bucket.state.arn]
      }, {
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${aws_s3_bucket.state.arn}/*"]
      }, {
      Effect = "Allow"
      Action = [
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviders",
      ]
      Resource = "*"
      }, {
      Effect = "Allow"
      Action = ["kms:DescribeKey"]
      Resource = [
        "arn:aws:kms:eu-central-1:${data.aws_caller_identity.current.account_id}:key/*",
        "arn:aws:kms:eu-west-1:${data.aws_caller_identity.current.account_id}:key/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "terraform_state" {
  name = "${var.project_name}-terraform-state"
  role = aws_iam_role.terraform_github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
      Resource = [aws_s3_bucket.state.arn]
      }, {
      Effect   = "Allow"
      Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      Resource = ["${aws_s3_bucket.state.arn}/*"]
    }]
  })
}

# Broad non-IAM access avoids brittle first-deploy failures; CloudTrail and Access Analyzer evidence will replace it with a least-privilege policy after M6.
resource "aws_iam_role_policy_attachment" "terraform_power_user" {
  role       = aws_iam_role.terraform_github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "terraform_workload" {
  name = "${var.project_name}-terraform-iam"
  role = aws_iam_role.terraform_github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-github-actions",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-vpc-flow-logs",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-rds-monitoring",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-vpc-flow-logs",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-rds-monitoring",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-github-actions",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-vpc-flow-logs",
        ]
      },
      {
        Sid    = "PassWorkloadRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-vpc-flow-logs",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-prod-rds-monitoring",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-vpc-flow-logs",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-dr-rds-monitoring",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-ecs-task-exec",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-ecs-task",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-monitoring-vpc-flow-logs",
        ]
      },
      {
        Sid    = "ReadGitHubOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
        ]
        Resource = aws_iam_openid_connect_provider.github.arn
      },
      {
        Sid      = "ListGitHubOIDCProviders"
        Effect   = "Allow"
        Action   = ["iam:ListOpenIDConnectProviders"]
        Resource = "*"
      },
      {
        Sid      = "CreateServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "ecs.amazonaws.com",
              "elasticloadbalancing.amazonaws.com",
              "rds.amazonaws.com",
              "monitoring.rds.amazonaws.com",
            ]
          }
        }
      },
    ]
  })
}
