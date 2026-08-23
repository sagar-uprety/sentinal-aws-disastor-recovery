variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name, used to derive the deployment-failure rule's default service ARN scope."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch alarm dimensions."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ARN suffix of the ALB target group, for CloudWatch alarm dimensions."
  type        = string
}

variable "ecs_desired_count" {
  description = "Desired ECS task count; 0 relaxes the ALB healthy-host alarm for pilot-light standby."
  type        = number
  default     = 2
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic."
  type        = string
}

variable "create_rds_alarms" {
  description = "Create the RDS CPU/free-storage alarms. False for environments with no RDS instance."
  type        = bool
  default     = true
}

variable "deployment_failed_service_arns" {
  description = "ECS service ARNs matched by the deployment-failure rule. Null (default) self-scopes to this service."
  type        = list(string)
  default     = null
}
