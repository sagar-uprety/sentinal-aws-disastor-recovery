output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider, consumed by every environment's app-deploy-iam module call."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "terraform_apply_role_arn" {
  description = "ARN of the role GitHub Actions assumes to apply Terraform."
  value       = aws_iam_role.terraform_github_apply.arn
}

output "terraform_plan_role_arn" {
  description = "ARN of the role GitHub Actions assumes for read-only PR plans."
  value       = aws_iam_role.terraform_github_plan.arn
}
