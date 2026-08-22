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
  description = "ARN of the ECR repository ecs-url-shortener.yml pushes images to."
  type        = string
}

variable "image_digest_parameter_arn" {
  description = "ARN of the SSM parameter CI writes the image digest to; Terraform reads it back on the next apply."
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster ecs-url-shortener.yml deploys to."
  type        = string
}

variable "ecs_service_arn" {
  description = "ARN of the ECS service ecs-url-shortener.yml updates."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role passed by ecs-url-shortener.yml when registering a task definition."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ARN of the ECS workload task role passed by ecs-url-shortener.yml when registering a task definition."
  type        = string
}

variable "secondary_ecr_repository_arn" {
  description = "ARN of the replicated secondary ECR repository checked by deployments. Null without a secondary."
  type        = string
  default     = null
}

variable "secondary_ecs_cluster_arn" {
  description = "ARN of the secondary ECS cluster updated by application deployments. Null without a secondary."
  type        = string
  default     = null
}

variable "secondary_ecs_service_arn" {
  description = "ARN of the secondary ECS service updated by application deployments. Null without a secondary."
  type        = string
  default     = null
}

variable "secondary_ecs_task_execution_role_arn" {
  description = "ARN of the secondary ECS task-execution role registered for task definitions. Null with no secondary."
  type        = string
  default     = null
}

variable "secondary_ecs_task_role_arn" {
  description = "ARN of the secondary ECS task role registered for task definitions. Null with no secondary."
  type        = string
  default     = null
}
