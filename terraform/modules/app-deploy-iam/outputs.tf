output "role_arn" {
  description = "ARN of the IAM role ecs-url-shortener.yml assumes through GitHub OIDC."
  value       = aws_iam_role.github_actions.arn
}
