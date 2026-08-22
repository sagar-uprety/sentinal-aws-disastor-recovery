variable "domain_name" {
  description = "Domain name the certificate covers."
  type        = string
}

variable "route53_zone_id" {
  description = "Zone ID to create DNS validation records in."
  type        = string
}

variable "create_validation_records" {
  description = "Create the DNS validation CNAME records. False if a prior request already left a reusable record."
  type        = bool
  default     = true
}
