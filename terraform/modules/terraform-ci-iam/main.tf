# identity for GitHub Actions to run Terraform itself (apply/plan); app-deploy-iam builds the separate,
# narrower per-environment roles that deploy application images once infra already exists.
data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Read-only AWS and state access, so PR speculative plans never touch production.
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
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:pull_request"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_read_only" {
  role       = aws_iam_role.terraform_github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# CI cannot create the credentials it needs to run. Bootstrap breaks that loop: applied once
# by hand, then left in place so every later deploy runs through CI normally.
resource "aws_iam_role" "terraform_github_apply" {
  name = "${var.project_name}-terraform-github-apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = format(
            "repo:%s/%s:environment:terraform-production",
            var.github_org, var.github_repo,
          )
        }
      }
    }]
  })
}

# PowerUserAccess avoids maintaining an exact permission list for everything Terraform manages
# here; a real production environment should scope this down.

resource "aws_iam_role_policy_attachment" "terraform_power_user" {
  role       = aws_iam_role.terraform_github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "terraform_workload" {
  name = "${var.project_name}-terraform-iam"
  role = aws_iam_role.terraform_github_apply.id

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
        Resource = local.manage_role_arns
      },
      {
        Sid      = "PassWorkloadRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.pass_role_arns
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
    ]
  })
}
