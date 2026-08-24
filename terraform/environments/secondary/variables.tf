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
