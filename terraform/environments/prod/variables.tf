variable "deploy_service" {
  description = "Create the ECS service. Set false for foundation phase."
  type        = bool
  default     = false
}

variable "desired_count" {
  description = "Desired ECS task count for prod. Set to 0 while prod is rebuilt as a failback replica."
  type        = number
  default     = 2
}

variable "image_digest" {
  description = "Immutable ECR image digest for the ECS service, set after the phase 2 image push."
  type        = string
  default     = "sha256:d5582834638054260ffa8ae62302f815ac743c818bfedf546b2d94080730f23c"
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

variable "replicate_source_db_arn" {
  description = "Temporary source DB ARN used only while rebuilding prod as a failback replica."
  type        = string
  default     = null

  validation {
    condition     = var.replicate_source_db_arn == null || can(regex("^arn:aws:rds:[a-z0-9-]+:[0-9]{12}:db:[a-zA-Z0-9-]+$", var.replicate_source_db_arn))
    error_message = "replicate_source_db_arn must be null or an RDS DB instance ARN."
  }
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
