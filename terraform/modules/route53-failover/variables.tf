variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone ID of the delegated pilotlight.sagaruprety.com.np zone."
  type        = string
}

variable "record_name" {
  description = "Fully qualified record name where the failover pair publishes the application."
  type        = string
}

variable "primary_alb_dns_name" {
  description = "DNS name of the primary (primary) ALB."
  type        = string
}

variable "primary_alb_zone_id" {
  description = "Canonical hosted zone ID of the primary (primary) ALB."
  type        = string
}

variable "secondary_alb_dns_name" {
  description = "DNS name of the secondary ALB."
  type        = string
}

variable "secondary_alb_zone_id" {
  description = "Canonical hosted zone ID of the secondary ALB."
  type        = string
}
