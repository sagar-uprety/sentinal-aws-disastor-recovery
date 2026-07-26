variable "deploy_service" {
  description = "Create the monitor ECS task definition and service after publishing an image."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email endpoint subscribed to isolated monitor alarms."
  type        = string
  default     = "sagarupreti100@gmail.com"
}

variable "github_org" {
  description = "GitHub organization or user trusted to deploy the monitor."
  type        = string
  default     = "sagar-uprety"
}

variable "github_repo" {
  description = "GitHub repository trusted to deploy the monitor."
  type        = string
  default     = "sentinal-aws-disastor-recovery"
}

variable "image_digest" {
  description = "Immutable monitor image digest used for initial ECS service creation."
  type        = string
  default     = "sha256:ebb7d99a639d5bf9a20052757f890d76a5aad4118ebe1fd016275aadf23fbc9a"
}
