# GitHub OIDC Module

IAM role assumed via GitHub OIDC (no long-lived AWS keys) so `ecs-url-shortener.yml` can push images and deploy ECS. Trust policy is pinned to the exact repo and the protected `production` GitHub environment. Permissions scope to one ECR repo, the prod and DR ECS services/task roles by ARN, and task-definition register/describe, which AWS doesn't support scoping further.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.55.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_role.github_actions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.workload_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_dr_ecr_repository_arn"></a> [dr\_ecr\_repository\_arn](#input\_dr\_ecr\_repository\_arn) | ARN of the replicated DR ECR repository checked by deployments. Null when there's no DR pair. | `string` | `null` | no |
| <a name="input_dr_ecs_cluster_arn"></a> [dr\_ecs\_cluster\_arn](#input\_dr\_ecs\_cluster\_arn) | ARN of the DR ECS cluster updated by application deployments. Null for environments with no DR pair. | `string` | `null` | no |
| <a name="input_dr_ecs_service_arn"></a> [dr\_ecs\_service\_arn](#input\_dr\_ecs\_service\_arn) | ARN of the DR ECS service updated by application deployments. Null for environments with no DR pair. | `string` | `null` | no |
| <a name="input_dr_ecs_task_execution_role_arn"></a> [dr\_ecs\_task\_execution\_role\_arn](#input\_dr\_ecs\_task\_execution\_role\_arn) | ARN of the DR ECS task execution role passed when registering a task definition. Null with no DR pair. | `string` | `null` | no |
| <a name="input_dr_ecs_task_role_arn"></a> [dr\_ecs\_task\_role\_arn](#input\_dr\_ecs\_task\_role\_arn) | ARN of the DR ECS task role passed when registering a task definition. Null with no DR pair. | `string` | `null` | no |
| <a name="input_ecr_repository_arn"></a> [ecr\_repository\_arn](#input\_ecr\_repository\_arn) | ARN of the ECR repository ecs-url-shortener.yml pushes images to. | `string` | n/a | yes |
| <a name="input_ecs_cluster_arn"></a> [ecs\_cluster\_arn](#input\_ecs\_cluster\_arn) | ARN of the ECS cluster ecs-url-shortener.yml deploys to. | `string` | n/a | yes |
| <a name="input_ecs_service_arn"></a> [ecs\_service\_arn](#input\_ecs\_service\_arn) | ARN of the ECS service ecs-url-shortener.yml updates. | `string` | n/a | yes |
| <a name="input_ecs_task_execution_role_arn"></a> [ecs\_task\_execution\_role\_arn](#input\_ecs\_task\_execution\_role\_arn) | ARN of the ECS task execution role passed by ecs-url-shortener.yml when registering a task definition. | `string` | n/a | yes |
| <a name="input_ecs_task_role_arn"></a> [ecs\_task\_role\_arn](#input\_ecs\_task\_role\_arn) | ARN of the ECS workload task role passed by ecs-url-shortener.yml when registering a task definition. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#input\_github\_oidc\_provider\_arn) | ARN of the shared GitHub Actions OIDC provider created by bootstrap. | `string` | n/a | yes |
| <a name="input_github_org"></a> [github\_org](#input\_github\_org) | GitHub organization or user that owns the repository. | `string` | n/a | yes |
| <a name="input_github_repo"></a> [github\_repo](#input\_github\_repo) | GitHub repository name (without owner). | `string` | n/a | yes |
| <a name="input_image_digest_parameter_arn"></a> [image\_digest\_parameter\_arn](#input\_image\_digest\_parameter\_arn) | ARN of the SSM parameter CI writes the image digest to; Terraform reads it back on the next apply. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of the IAM role ecs-url-shortener.yml assumes through GitHub OIDC. |
<!-- END_TF_DOCS -->
