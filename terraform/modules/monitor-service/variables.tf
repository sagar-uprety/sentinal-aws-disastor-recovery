variable "alb_security_group_id" {
  description = "ID of the ALB security group allowed to reach monitor tasks."
  type        = string
}

variable "app_subnet_ids" {
  description = "IDs of private subnets for monitor tasks."
  type        = list(string)
}

variable "container_port" {
  description = "Container port for monitor HTTP traffic."
  type        = number
  default     = 8080
}

variable "deploy_service" {
  description = "Create the monitor task definition and ECS service."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Number of isolated monitor tasks to run."
  type        = number
  default     = 1
}

variable "dr_database_identifier" {
  description = "DR RDS instance identifier observed by the monitor."
  type        = string
}

variable "dr_ecs_cluster" {
  description = "DR ECS cluster name observed by the monitor."
  type        = string
}

variable "dr_ecs_service" {
  description = "DR ECS service name observed by the monitor."
  type        = string
}

variable "dr_region" {
  description = "AWS Region containing the DR workload."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the monitor-owned DynamoDB table."
  type        = string
}

variable "dynamodb_table_name" {
  description = "Name of the monitor-owned DynamoDB table."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "image_uri" {
  description = "Monitor ECR image URI with immutable digest."
  type        = string
}

variable "monitored_url" {
  description = "Canonical workload health URL checked by the monitor."
  type        = string
}

variable "prod_database_identifier" {
  description = "Prod RDS instance identifier observed by the monitor."
  type        = string
}

variable "prod_ecs_cluster" {
  description = "Prod ECS cluster name observed by the monitor."
  type        = string
}

variable "prod_ecs_service" {
  description = "Prod ECS service name observed by the monitor."
  type        = string
}

variable "prod_region" {
  description = "AWS Region containing the primary workload."
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the monitor ALB target group."
  type        = string
}

variable "task_cpu" {
  description = "CPU units per monitor task."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory in MiB per monitor task."
  type        = number
  default     = 512
}

variable "vpc_id" {
  description = "ID of the isolated monitoring VPC."
  type        = string
}
