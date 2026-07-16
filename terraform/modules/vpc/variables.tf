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
  # Matches what's actually deployed (prod's db subnets were created with
  # newbits=3, same as app). Do not change this default without planning a
  # live RDS subnet migration first: it forces subnet replacement, which
  # AWS blocks while an RDS instance's ENI is attached to the subnet.
  default = 3
}

variable "create_s3_endpoint" {
  description = "Provision a free S3 gateway endpoint."
  type        = bool
  default     = true
}

# tflint-ignore: terraform_unused_declarations
variable "create_interface_endpoints" {
  description = "Provision paid VPC interface endpoints (ecr.api, ecr.dkr, logs, ssm). Not yet implemented: no aws_vpc_endpoint resources exist for this var."
  type        = bool
  default     = false
}
