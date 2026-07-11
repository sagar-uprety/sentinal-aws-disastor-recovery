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

variable "db_subnet_ids" {
  description = "IDs of the isolated database subnets."
  type        = list(string)
}

variable "ecs_security_group_id" {
  description = "ID of the ECS security group granted access to the database."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version resolved via aws_rds_engine_version."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class (e.g., db.t4g.micro)."
  type        = string
}

variable "password_wo" {
  description = "Master database password (write-only)."
  type        = string
}

variable "password_wo_version" {
  description = "Version counter for password_wo rotation."
  type        = number
}

variable "multi_az" {
  description = "Enable Multi-AZ for high availability testing."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name of the application database."
  type        = string
  default     = "sentinel"
}

variable "username" {
  description = "Master database username."
  type        = string
  default     = "sentinel"
}
