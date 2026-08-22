variable "deploy_service" {
  description = "Create the monitor ECS task definition and service after publishing an image."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email endpoint subscribed to isolated monitor alarms."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or user trusted to deploy the monitor."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository trusted to deploy the monitor."
  type        = string
}
