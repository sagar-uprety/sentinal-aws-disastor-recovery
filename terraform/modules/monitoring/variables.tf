variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name used in the running-task-count alarm."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch alarm dimensions."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ARN suffix of the ALB target group, for CloudWatch alarm dimensions."
  type        = string
}

variable "ecs_desired_count" {
  description = "Desired ECS task count for the app service, used as the running-task-count alarm threshold."
  type        = number
  default     = 2
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic."
  type        = string
}
