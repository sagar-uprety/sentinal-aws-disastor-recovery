output "role_arn" {
  description = "ARN of the IAM role workload.yml assumes through GitHub OIDC."
  value       = aws_iam_role.github_actions.arn
}
