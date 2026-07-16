variable "deploy_service" {
  description = "Create the ECS service. Set false for foundation phase."
  type        = bool
  default     = false
}

variable "credential_version" {
  description = "Increment to rotate the database password across RDS and both SSM parameters."
  type        = number
  default     = 1
}

variable "multi_az" {
  description = "Enable RDS Multi-AZ for high availability testing."
  type        = bool
  default     = false
}
