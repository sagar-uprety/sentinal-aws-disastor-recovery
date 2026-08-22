output "alb_dns_name" {
  description = "Public ALB DNS name for the secondary URL-shortener workload."
  value       = module.alb.alb_dns_name
}

output "rds_replica_arn" {
  description = "ARN of the secondary RDS read replica, used by failover.sh for promotion."
  value       = module.rds.arn
}

output "rds_replica_endpoint" {
  description = "Secondary RDS read replica connection endpoint."
  value       = module.rds.endpoint
}

output "sns_topic_arn" {
  description = "SNS topic ARN that secondary CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = module.monitoring.sns_topic_arn
}
