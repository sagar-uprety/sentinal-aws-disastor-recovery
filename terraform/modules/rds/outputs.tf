output "endpoint" {
  description = "RDS connection endpoint."
  value       = aws_db_instance.main.endpoint
}

output "address" {
  description = "RDS hostname."
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS port."
  value       = aws_db_instance.main.port
}

output "security_group_id" {
  description = "ID of the RDS security group."
  value       = aws_security_group.rds.id
}
