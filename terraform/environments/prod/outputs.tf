output "alb_dns_name" {
  description = "Public ALB DNS name for the Sentinel status page."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the prod ALB, read by the DR environment's Route53 alias record via remote state."
  value       = module.alb.alb_zone_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Sentinel image."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (set as the AWS_ROLE_ARN repo variable for app.yml)."
  value       = module.github_oidc.role_arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}

output "database_password_dr_ssm_arn" {
  description = "ARN of the DR-region SSM SecureString parameter holding the database password, read by the DR environment via remote state."
  value       = aws_ssm_parameter.database_password_dr.arn
}

output "dr_certificate_arn" {
  description = "Validated ACM certificate ARN for the eu-west-1 DR ALB."
  value       = aws_acm_certificate_validation.dr.certificate_arn
}

output "image_digest" {
  description = "Immutable ECR image digest currently deployed to prod, read by the DR environment via remote state so it deploys the same image."
  value       = var.image_digest
}

output "rds_engine_version" {
  description = "Resolved PostgreSQL engine version running in prod, read by the DR environment to validate the replica matches before creation."
  value       = data.aws_rds_engine_version.postgres.version
}

output "rds_instance_arn" {
  description = "ARN of the prod RDS instance, used as the replication source for the DR cross-region read replica."
  value       = module.rds.arn
}

output "rds_instance_class" {
  description = "Instance class of the prod RDS instance, read by the DR environment so the replica matches the same Graviton class."
  value       = "db.t4g.micro"
}

output "route53_zone_id" {
  description = "Hosted zone ID for sentinel.sagaruprety.com.np, read by DR Route53 records."
  value       = data.aws_route53_zone.sentinel.zone_id
}

output "route53_zone_name_servers" {
  description = "NS records delegated from the Cloudflare-managed parent zone."
  value       = data.aws_route53_zone.sentinel.name_servers
}
