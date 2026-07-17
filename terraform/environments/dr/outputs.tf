output "alb_dns_name" {
  description = "Public ALB DNS name for the DR Sentinel status page."
  value       = module.alb.alb_dns_name
}

output "grafana_service_name" {
  description = "ECS service name for DR Grafana, used with SSM port-forward to reach the dashboard."
  value       = module.monitoring.grafana_service_name
}

output "route53_zone_id" {
  description = "Hosted zone ID for sentinel.sagaruprety.com.np, used by the route53-failover module."
  value       = aws_route53_zone.sentinel.zone_id
}

output "route53_zone_name_servers" {
  description = "NS nameservers for sentinel.sagaruprety.com.np, added as a delegation record in the Cloudflare-managed parent zone."
  value       = aws_route53_zone.sentinel.name_servers
}

output "rds_replica_arn" {
  description = "ARN of the DR RDS read replica, used by failover.sh for promotion."
  value       = module.rds.arn
}

output "rds_replica_endpoint" {
  description = "DR RDS read replica connection endpoint."
  value       = module.rds.endpoint
}

output "sns_topic_arn" {
  description = "SNS topic ARN that DR CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}
