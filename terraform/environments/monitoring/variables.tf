variable "deploy_service" {
  description = "Create the sentry ECS task definition and service after publishing an image."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email endpoint subscribed to isolated sentry alarms."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or user trusted to deploy the sentry."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository trusted to deploy the sentry."
  type        = string
}
