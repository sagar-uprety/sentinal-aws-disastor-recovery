output "alb_dns_name" {
  description = "Public ALB DNS name for the DR Sentinel status page."
  value       = module.alb.alb_dns_name
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
