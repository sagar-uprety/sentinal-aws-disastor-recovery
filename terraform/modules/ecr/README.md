# ECR Module

Private image registry, KMS-encrypted (AWS-managed `alias/aws/ecr` key). `IMMUTABLE` tags prevent overwriting a pushed digest; lifecycle policy keeps the last 10 images; scan-on-push is enabled. `force_delete = true` so `terraform destroy` doesn't require emptying the repo first (as this is a demo-project).

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
| [aws_ecr_lifecycle_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_app_name"></a> [app\_name](#input\_app\_name) | Application the repository holds images for, e.g. url-shortener or sentry. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_repository_arn"></a> [repository\_arn](#output\_repository\_arn) | ARN of the ECR repository. |
| <a name="output_repository_url"></a> [repository\_url](#output\_repository\_url) | URL of the ECR repository. |
<!-- END_TF_DOCS -->
