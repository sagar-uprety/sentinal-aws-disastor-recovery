variable "project_name" {
  description = "Project name for resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
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

variable "github_oidc_provider_arn" {
  description = "ARN of the shared GitHub Actions OIDC provider created by bootstrap."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository app.yml pushes images to."
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster app.yml deploys to."
  type        = string
}

variable "ecs_service_arn" {
  description = "ARN of the ECS service app.yml updates."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role that app.yml must be able to pass when registering a new task definition revision."
  type        = string
}
