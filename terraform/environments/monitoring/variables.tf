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

variable "base_domain" {
  description = "Delegated subdomain that hosts every project record, e.g. pilotlight.example.com."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.base_domain))
    error_message = "base_domain must be a lowercase DNS name with no scheme, port, or trailing dot."
  }
}
