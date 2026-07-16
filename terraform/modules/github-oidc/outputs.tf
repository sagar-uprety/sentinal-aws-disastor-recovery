output "role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC (used as AWS_ROLE_ARN in app.yml)."
  value       = aws_iam_role.github_actions.arn
}
