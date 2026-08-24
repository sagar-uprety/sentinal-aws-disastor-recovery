variable "github_org" {
  description = "GitHub organization or user allowed to assume bootstrap OIDC roles."
  type        = string
  default     = "sagar-uprety"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume bootstrap OIDC roles."
  type        = string
  default     = "aws-pilotlight-multi-region-dr"
}

variable "state_bucket_name" {
  description = "Globally unique name of the S3 bucket that stores Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "State bucket name must be a valid S3 bucket name between 3 and 63 characters."
  }
}
