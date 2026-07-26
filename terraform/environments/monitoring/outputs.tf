output "alb_dns_name" {
  description = "DNS name of the isolated monitoring ALB."
  value       = module.alb.alb_dns_name
}

output "dynamodb_table_name" {
  description = "Name of the monitor-owned check-history table."
  value       = aws_dynamodb_table.checks.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for monitor images."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role assumed by monitor deployments."
  value       = aws_iam_role.github_actions.arn
}

output "monitor_url" {
  description = "Canonical isolated monitoring URL."
  value       = "https://${local.app_hostname}"
}
