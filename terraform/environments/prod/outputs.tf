output "alb_dns_name" {
  description = "Public ALB DNS name for the Sentinel status page."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the prod ALB."
  value       = module.alb.alb_zone_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Sentinel image."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC for workload.yml."
  value       = module.github_oidc.role_arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}

output "route53_zone_id" {
  description = "Hosted zone ID for sentinel.sagaruprety.com.np."
  value       = data.aws_route53_zone.sentinel.zone_id
}

output "route53_zone_name_servers" {
  description = "NS records delegated from the Cloudflare-managed parent zone."
  value       = data.aws_route53_zone.sentinel.name_servers
}
