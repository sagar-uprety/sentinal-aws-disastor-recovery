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

variable "alb_security_group_id" {
  description = "ID of the ALB security group allowed to send HTTP traffic."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the ALB target group."
  type        = string
}

variable "image_uri" {
  description = "ECR image URI with immutable digest."
  type        = string
}

variable "db_endpoint" {
  description = "RDS connection endpoint (host:port)."
  type        = string
}

variable "db_name" {
  description = "Application database name."
  type        = string
}

variable "db_user" {
  description = "Database master username."
  type        = string
}

variable "db_password_ssm_arn" {
  description = "ARN of the SSM SecureString parameter holding the database password."
  type        = string
}

variable "link_create_token_ssm_arn" {
  description = "ARN of the SSM SecureString parameter holding the URL-shortener operator token."
  type        = string
}

variable "deploy_service" {
  description = "Create the ECS service. Set false for the foundation phase."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Number of ECS tasks to run."
  type        = number
  default     = 2
}

variable "task_cpu" {
  description = "vCPU units per task."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory MiB per task."
  type        = number
  default     = 512
}

variable "container_port" {
  description = "Container port for HTTP traffic."
  type        = number
  default     = 8080
}
