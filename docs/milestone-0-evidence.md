# Milestone 0 Evidence

Verified on 2026-07-11 against AWS account `926883320788`.

## Tooling

- Terraform CLI: 1.15.5
- AWS provider: 6.54.0
- Random provider: deferred until its first use in Milestone 2 to satisfy `terraform_unused_required_providers`
- Bootstrap, prod, and DR require Terraform `>= 1.11, < 2.0`.
- `terraform fmt -check -recursive` passed.
- `terraform validate` passed in bootstrap, prod, and DR.
- `terraform plan -detailed-exitcode -input=false` returned no changes in bootstrap, prod, and DR after initialization and apply.

## Remote State

- State bucket: `sagar-demos-terraform-state`
- Region: `eu-central-1`
- Prod key: `sentinel/prod/terraform.tfstate`
- DR key: `sentinel/dr/terraform.tfstate`
- Active locking: native S3 lock files through `use_lockfile = true`
- Compatibility lock table: `sentinel-aws-dr-terraform-lock`, status `ACTIVE`, billing mode `PAY_PER_REQUEST`

Terraform 1.15 deprecates DynamoDB backend locking. The table remains provisioned to satisfy the original bootstrap design, while prod and DR use native S3 locking.

## Security Controls

- S3 versioning: `Enabled`
- Default S3 encryption: `AES256`
- Public ACLs blocked: true
- Public policies blocked: true
- Public ACLs ignored: true
- Public buckets restricted: true
- Bucket deletion protection: `force_destroy = false`
- Bucket and lock table tags: `Project=sentinel-aws-dr`, `ManagedBy=terraform`, `Environment=prod`, `Purpose=state-storage`

## Budget Check

Both owner-managed AWS budgets reported `HEALTHY` before the bootstrap apply:

| Budget | Limit | Actual spend at verification |
|---|---:|---:|
| 100$ limit | 100 USD | 0.000 USD |
| My Monthly Cost Budget | 30 USD | 0.011 USD |

Budgets remain owner-managed and are not imported into Terraform.
