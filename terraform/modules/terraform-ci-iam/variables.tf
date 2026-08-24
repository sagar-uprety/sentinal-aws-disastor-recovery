variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without owner)."
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the S3 state bucket, so the plan role can lock/unlock without ReadOnlyAccess."
  type        = string
}

variable "workload_environments" {
  description = "Environment names whose IAM roles this CI role may manage."
  type        = list(string)
  default     = ["primary", "secondary", "monitoring"]
}

# A genuinely new role kind needs one entry added here; an env x suffix combo that doesn't
# exist yet (e.g. monitoring has no rds-monitoring role) is a harmless unused ARN, not an error.
variable "manageable_role_suffixes" {
  description = "Role suffixes (after \"$${project_name}-{env}-\") this CI role may create/update/delete."
  type        = list(string)
  default     = ["github-actions", "ecs-task-exec", "ecs-task", "vpc-flow-logs", "rds-monitoring"]
}

# Deliberately excludes the github-actions/app-deploy role: it's assumed via STS, never passed
# to an AWS service.
variable "passable_role_suffixes" {
  description = "Role suffixes (after \"$${project_name}-{env}-\") this CI role may PassRole to ECS."
  type        = list(string)
  default     = ["ecs-task-exec", "ecs-task", "vpc-flow-logs", "rds-monitoring"]
}
