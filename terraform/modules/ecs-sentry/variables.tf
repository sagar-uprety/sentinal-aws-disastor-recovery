variable "alb_security_group_id" {
  description = "ID of the ALB security group allowed to reach sentry tasks."
  type        = string
}

variable "app_subnet_ids" {
  description = "IDs of private subnets for sentry tasks."
  type        = list(string)
}

variable "container_port" {
  description = "Container port for sentry HTTP traffic."
  type        = number
  default     = 8080
}

variable "deploy_service" {
  description = "Create the sentry task definition and ECS service."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Number of isolated sentry tasks to run."
  type        = number
  default     = 1
}

variable "secondary_database_identifier" {
  description = "Secondary RDS instance identifier observed by the sentry."
  type        = string
}

variable "secondary_ecs_cluster" {
  description = "Secondary ECS cluster name observed by the sentry."
  type        = string
}

variable "secondary_ecs_service" {
  description = "Secondary ECS service name observed by the sentry."
  type        = string
}

variable "secondary_region" {
  description = "AWS Region containing the secondary workload."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the sentry-owned DynamoDB table."
  type        = string
}

variable "dynamodb_table_name" {
  description = "Name of the sentry-owned DynamoDB table."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "image_uri" {
  description = "Sentry ECR image URI with immutable digest."
  type        = string
}

variable "monitored_url" {
  description = "Canonical workload health URL checked by the sentry."
  type        = string
}

variable "primary_database_identifier" {
  description = "Primary RDS instance identifier observed by the sentry."
  type        = string
}

variable "primary_ecs_cluster" {
  description = "Primary ECS cluster name observed by the sentry."
  type        = string
}

variable "primary_ecs_service" {
  description = "Primary ECS service name observed by the sentry."
  type        = string
}

variable "primary_region" {
  description = "AWS Region containing the primary workload."
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the sentry ALB target group."
  type        = string
}

variable "task_cpu" {
  description = "CPU units per sentry task."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory in MiB per sentry task."
  type        = number
  default     = 512
}

variable "vpc_id" {
  description = "ID of the isolated monitoring VPC."
  type        = string
}
