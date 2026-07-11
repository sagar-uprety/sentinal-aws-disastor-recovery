variable "project_name" {
  description = "Project name used for resource names and tags."
  type        = string

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "Project name must not be empty."
  }
}

variable "state_bucket_name" {
  description = "Globally unique name of the S3 bucket that stores Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "State bucket name must be a valid S3 bucket name between 3 and 63 characters."
  }
}
