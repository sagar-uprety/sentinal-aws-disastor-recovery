output "alb_dns_name" {
  description = "Public ALB DNS name for the Sentinel status page."
  value       = module.alb.alb_dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Sentinel image."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (set as the AWS_ROLE_ARN repo variable for app.yml)."
  value       = module.github_oidc.role_arn
}

output "grafana_service_name" {
  description = "ECS service name for Grafana, used with SSM port-forward to reach the dashboard."
  value       = module.monitoring.grafana_service_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}
