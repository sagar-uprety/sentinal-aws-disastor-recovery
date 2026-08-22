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

variable "dr_ecr_repository_arn" {
  description = "ARN of the replicated DR ECR repository checked by deployments. Null when there's no DR pair."
  type        = string
  default     = null
}

variable "dr_ecs_cluster_arn" {
  description = "ARN of the DR ECS cluster updated by application deployments. Null for environments with no DR pair."
  type        = string
  default     = null
}

variable "dr_ecs_service_arn" {
  description = "ARN of the DR ECS service updated by application deployments. Null for environments with no DR pair."
  type        = string
  default     = null
}

variable "dr_ecs_task_execution_role_arn" {
  description = "ARN of the DR ECS task execution role passed when registering a task definition. Null with no DR pair."
  type        = string
  default     = null
}

variable "dr_ecs_task_role_arn" {
  description = "ARN of the DR ECS task role passed when registering a task definition. Null with no DR pair."
  type        = string
  default     = null
}
