variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC."
  type        = string
}

variable "app_subnet_ids" {
  description = "IDs of the application private subnets."
  type        = list(string)
}

variable "ecs_cluster_name" {
  description = "Name of the existing ECS cluster to run the monitoring services in."
  type        = string
}

variable "app_security_group_id" {
  description = "Security group ID of the Sentinel app ECS tasks, allowed to push OTLP metrics to the collector."
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
