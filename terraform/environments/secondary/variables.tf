variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alerts SNS topic."
  type        = string
}

variable "desired_count" {
  description = "Desired secondary ECS task count; 0 (pilot light) until an operator scales up on failover."
  type        = number
  default     = 0
}

variable "multi_az" {
  description = "Enable RDS Multi-AZ for secondary. False until measured post-promotion conversion (plan.md 4.8)."
  type        = bool
  default     = false
}

variable "create_arc" {
  description = "Provision the Route53 ARC cluster/records for a drill ($2.50/cluster-hour). Off by default."
  type        = bool
  default     = false
}

variable "base_domain" {
  description = "Delegated subdomain that hosts every project record, e.g. pilotlight.example.com."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.base_domain))
    error_message = "base_domain must be a lowercase DNS name with no scheme, port, or trailing dot."
  }
}
