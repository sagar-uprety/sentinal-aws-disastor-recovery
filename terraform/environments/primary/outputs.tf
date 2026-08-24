output "alb_dns_name" {
  description = "Public ALB DNS name for the URL-shortener workload."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the primary ALB."
  value       = module.alb.alb_zone_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the URL-shortener image."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC for ecs-url-shortener.yml."
  value       = module.github_oidc.role_arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}

output "route53_zone_id" {
  description = "Hosted zone ID for the project base domain."
  value       = data.aws_route53_zone.pilotlight.zone_id
}

output "route53_zone_name_servers" {
  description = "Nameservers of the project base-domain zone."
  value       = data.aws_route53_zone.pilotlight.name_servers
}

# Lets CI gate ECS health checks on the applied value instead of a separate workflow input.
output "deploy_service" {
  description = "Whether this apply created the ECS service."
  value       = var.deploy_service
}
