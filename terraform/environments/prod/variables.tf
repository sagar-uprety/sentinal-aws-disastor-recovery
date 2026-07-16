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

variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alerts SNS topic."
  type        = string
  default     = "sagarupreti100@gmail.com"
}

variable "github_org" {
  description = "GitHub org/user that owns this repository, for the OIDC trust policy."
  type        = string
  default     = "sagar-uprety"
}

variable "github_repo" {
  description = "GitHub repository name, for the OIDC trust policy."
  type        = string
  default     = "sentinal-aws-disastor-recovery"
}
