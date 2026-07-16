# VPC Module

Two-AZ VPC with separate routing tiers: public (ALB), application (ECS), isolated database (RDS).

## Design Intent

Each tier has its own route table. Public subnets route through an internet gateway, application subnets route through a Regional NAT Gateway spanning both AZs, and database subnets have no internet routes. Subnet sizes are calculated with `cidrsubnet` using configurable newbits for each tier. The free S3 gateway endpoint is enabled by default.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name for resource naming | `string` | — |
| `environment` | Deployment environment name | `string` | — |
| `vpc_cidr` | CIDR block for the VPC | `string` | — |
| `availability_zones` | Availability zones to use | `list(string)` | — |
| `public_subnet_newbits` | Additional netmask bits for public subnets | `number` | `3` |
| `app_subnet_newbits` | Additional netmask bits for app subnets | `number` | `3` |
| `db_subnet_newbits` | Additional netmask bits for database subnets | `number` | `4` |
| `create_s3_endpoint` | Provision S3 gateway endpoint | `bool` | `true` |
| `create_interface_endpoints` | Provision paid interface endpoints | `bool` | `false` |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the VPC |
| `public_subnet_ids` | IDs of the public subnets |
| `app_subnet_ids` | IDs of the application private subnets |
| `db_subnet_ids` | IDs of the isolated database subnets |
| `nat_gateway_id` | ID of the Regional NAT Gateway |

## Cost

One Regional NAT Gateway is billed per supported AZ. Elastic IPs are free when attached. The S3 gateway endpoint has no hourly charge.
