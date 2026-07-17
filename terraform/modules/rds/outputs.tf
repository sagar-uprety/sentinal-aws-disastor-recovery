output "address" {
  description = "RDS hostname."
  value       = one(concat(aws_db_instance.main[*].address, aws_db_instance.replica[*].address))
}

output "arn" {
  description = "ARN of the RDS instance, for cross-region replication and IAM policies."
  value       = one(concat(aws_db_instance.main[*].arn, aws_db_instance.replica[*].arn))
}

output "endpoint" {
  description = "RDS connection endpoint."
  value       = one(concat(aws_db_instance.main[*].endpoint, aws_db_instance.replica[*].endpoint))
}

output "port" {
  description = "RDS port."
  value       = one(concat(aws_db_instance.main[*].port, aws_db_instance.replica[*].port))
}

output "security_group_id" {
  description = "ID of the RDS security group."
  value       = aws_security_group.rds.id
}
