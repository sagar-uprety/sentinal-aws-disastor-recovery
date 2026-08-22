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
  description = "Master password (write-only). Ignored for replicas, which inherit the source instance's credentials."
  type        = string
  default     = ""
  sensitive   = true
  ephemeral   = true
}

variable "password_wo_version" {
  description = "Version counter for password_wo rotation. Ignored when replicate_source_db_arn is set."
  type        = number
  default     = 1
}

variable "replicate_source_db_arn" {
  description = "ARN of the source RDS instance; set to create a cross-region replica instead of a standalone instance."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "Destination-region KMS key ARN for replica storage. Required when replicate_source_db_arn is set."
  type        = string
  default     = null
}

variable "multi_az" {
  description = "Enable Multi-AZ for high availability testing."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name of the application database."
  type        = string
  default     = "pilotlight"
}

variable "username" {
  description = "Master database username."
  type        = string
  default     = "pilotlight"
}
