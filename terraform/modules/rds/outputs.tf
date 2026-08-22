output "arn" {
  description = "ARN of the RDS instance, for cross-region replication and IAM policies."
  value       = aws_db_instance.main.arn
}

output "endpoint" {
  description = "RDS connection endpoint."
  value       = aws_db_instance.main.endpoint
}

output "security_group_id" {
  description = "ID of the RDS security group."
  value       = aws_security_group.rds.id
}
