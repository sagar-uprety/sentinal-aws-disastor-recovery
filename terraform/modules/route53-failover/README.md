# Route53 Failover Module

Operator-gated traffic switching between prod and DR via Route53 Application Recovery Controller (ARC).

## Design Intent

Two Route53 failover records at the same name, each health-gated by a `RECOVERY_CONTROL` health check tied to an ARC routing control's manual On/Off state rather than real ALB health -- so the DNS switch only ever happens when an operator (or a script acting on their behalf) flips the ARC control via its data-plane API, never automatically. Two safety rules block the cluster from ever having both controls On or both Off simultaneously.

## Cost

The ARC cluster is billed per cluster-hour while it exists (published rate $2.50/cluster-hour at last check; verify current pricing before apply). Provision only for the drill and destroy after recording, per the project owner's teardown decision. The two `aws_route53_health_check` resources and Route53 records are billed at Route53's normal per-health-check / per-hosted-zone rates, not part of the ARC hourly charge.

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
| [aws_route53_health_check.dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_health_check.dr_detection](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_health_check.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_health_check.primary_detection](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_record.dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53recoverycontrolconfig_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_cluster) | resource |
| [aws_route53recoverycontrolconfig_control_panel.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_control_panel) | resource |
| [aws_route53recoverycontrolconfig_routing_control.dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_routing_control) | resource |
| [aws_route53recoverycontrolconfig_routing_control.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_routing_control) | resource |
| [aws_route53recoverycontrolconfig_safety_rule.not_both_off](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_safety_rule) | resource |
| [aws_route53recoverycontrolconfig_safety_rule.not_both_on](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_safety_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_dr_alb_dns_name"></a> [dr\_alb\_dns\_name](#input\_dr\_alb\_dns\_name) | DNS name of the DR ALB. | `string` | n/a | yes |
| <a name="input_dr_alb_zone_id"></a> [dr\_alb\_zone\_id](#input\_dr\_alb\_zone\_id) | Canonical hosted zone ID of the DR ALB. | `string` | n/a | yes |
| <a name="input_primary_alb_dns_name"></a> [primary\_alb\_dns\_name](#input\_primary\_alb\_dns\_name) | DNS name of the primary (prod) ALB. | `string` | n/a | yes |
| <a name="input_primary_alb_zone_id"></a> [primary\_alb\_zone\_id](#input\_primary\_alb\_zone\_id) | Canonical hosted zone ID of the primary (prod) ALB. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_record_name"></a> [record\_name](#input\_record\_name) | Fully qualified record name the failover pair is published under (e.g. status.sentinel.sagaruprety.com.np). | `string` | n/a | yes |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Hosted zone ID of the delegated sentinel.sagaruprety.com.np zone. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | ARN of the ARC routing control cluster. |
| <a name="output_dr_routing_control_arn"></a> [dr\_routing\_control\_arn](#output\_dr\_routing\_control\_arn) | ARN of the DR routing control, toggled via the ARC data-plane API to switch traffic. |
| <a name="output_primary_cluster_endpoints"></a> [primary\_cluster\_endpoints](#output\_primary\_cluster\_endpoints) | ARC data-plane endpoints, needed to call update-routing-control-state / get-routing-control-state (control-plane calls use the regular AWS API; data-plane calls require one of these region-specific endpoints). |
| <a name="output_primary_routing_control_arn"></a> [primary\_routing\_control\_arn](#output\_primary\_routing\_control\_arn) | ARN of the primary routing control, toggled via the ARC data-plane API to switch traffic. |
<!-- END_TF_DOCS -->
