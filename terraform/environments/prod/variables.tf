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

variable "credential_version" {
  description = "Increment to rotate the database password across RDS and both SSM parameters."
  type        = number
}

variable "link_token_version" {
  description = "Increment to rotate the URL-shortener operator token in both regional SSM parameters."
  type        = number
}

variable "multi_az" {
  description = "Enable RDS Multi-AZ."
  type        = bool
  default     = true
}

variable "replicate_source_db_arn" {
  description = "Temporary source DB ARN used only while rebuilding prod as a failback replica."
  type        = string
  default     = null

  validation {
    condition = var.replicate_source_db_arn == null || can(
      regex("^arn:aws:rds:[a-z0-9-]+:[0-9]{12}:db:[a-zA-Z0-9-]+$", var.replicate_source_db_arn)
    )
    error_message = "replicate_source_db_arn must be null or an RDS DB instance ARN."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alerts SNS topic."
  type        = string
}

variable "github_org" {
  description = "GitHub org/user that owns this repository, for the OIDC trust policy."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, for the OIDC trust policy."
  type        = string
}
