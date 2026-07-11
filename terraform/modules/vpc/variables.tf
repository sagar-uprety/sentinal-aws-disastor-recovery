variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones to use."
  type        = list(string)
}

variable "public_subnet_newbits" {
  description = "Number of additional bits for public subnet netmasks."
  type        = number
  default     = 3
}

variable "app_subnet_newbits" {
  description = "Number of additional bits for application subnet netmasks."
  type        = number
  default     = 3
}

variable "db_subnet_newbits" {
  description = "Number of additional bits for database subnet netmasks."
  type        = number
  default     = 4
}

variable "create_s3_endpoint" {
  description = "Provision a free S3 gateway endpoint."
  type        = bool
  default     = true
}

variable "create_interface_endpoints" {
  description = "Provision paid VPC interface endpoints (ecr.api, ecr.dkr, logs, ssm)."
  type        = bool
  default     = false
}
