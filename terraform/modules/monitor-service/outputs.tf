output "cluster_arn" {
  description = "ARN of the isolated monitoring ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  description = "Name of the isolated monitoring ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "security_group_id" {
  description = "ID of the monitor task security group."
  value       = aws_security_group.ecs.id
}

output "service_arn" {
  description = "ARN of the monitor ECS service, or null before service deployment."
  value       = var.deploy_service ? aws_ecs_service.main[0].id : null
}

output "task_execution_role_arn" {
  description = "ARN of the monitor ECS task execution role."
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ARN of the monitor ECS runtime role."
  value       = aws_iam_role.task.arn
}
