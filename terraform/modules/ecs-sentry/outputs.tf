output "cluster_arn" {
  description = "ARN of the isolated monitoring ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  description = "Name of the isolated monitoring ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "security_group_id" {
  description = "ID of the sentry task security group."
  value       = aws_security_group.ecs.id
}


output "task_execution_role_arn" {
  description = "ARN of the sentry ECS task execution role."
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ARN of the sentry ECS runtime role."
  value       = aws_iam_role.task.arn
}
