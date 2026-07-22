variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alerts SNS topic."
  type        = string
  default     = "sagarupreti100@gmail.com"
}

variable "desired_count" {
  description = "Desired ECS task count for the DR app service. 0 (pilot light) until an operator scales up during failover."
  type        = number
  default     = 0
}

variable "multi_az" {
  description = "Enable RDS Multi-AZ for the DR database. False until after a measured post-promotion conversion (section 4.8 drift row)."
  type        = bool
  default     = false
}

variable "create_arc" {
  description = "Provision the Route53 ARC routing-control cluster and failover records. Only needed during a drill ($2.50/cluster-hour). Off by default to save cost."
  type        = bool
  default     = false
}
