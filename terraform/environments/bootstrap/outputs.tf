output "state_bucket" {
  description = "Name of the S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "github_oidc_provider_arn" {
  description = "ARN of the shared GitHub Actions OIDC provider."
  value       = module.terraform_ci_iam.oidc_provider_arn
}

output "terraform_github_apply_role_arn" {
  description = "ARN of the GitHub Actions role that provisions Pilotlight infrastructure."
  value       = module.terraform_ci_iam.terraform_apply_role_arn
}

output "terraform_github_plan_role_arn" {
  description = "ARN of the read-only GitHub Actions role used for pull-request Terraform plans."
  value       = module.terraform_ci_iam.terraform_plan_role_arn
}

output "route53_zone_id" {
  description = "Persistent hosted zone ID for the delegated base domain."
  value       = aws_route53_zone.pilotlight.zone_id
}

output "route53_zone_name_servers" {
  description = "Nameservers delegated once from the Cloudflare-managed parent zone."
  value       = aws_route53_zone.pilotlight.name_servers
}
