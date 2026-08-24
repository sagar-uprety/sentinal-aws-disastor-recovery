# Route53 Failover Module

Operator-gated DNS failover between primary and secondary via Route53 Application Recovery Controller (ARC). Two failover records at the same name, each gated by a `RECOVERY_CONTROL` health check tied to an ARC routing control's manual On/Off state, not real ALB health, so the switch only happens when an operator (or a script acting on their behalf) flips the control via its data-plane API, never automatically. Two safety rules block both controls from being On or Off at once.

## Cost

The ARC cluster is billed per cluster-hour while it exists (published rate $2.50/cluster-hour at last check; verify current pricing before apply). Provision only for the drill and destroy after evidence capture, per the project owner's teardown decision. The two `aws_route53_health_check` resources and Route53 records are billed at Route53's normal per-health-check / per-hosted-zone rates, not part of the ARC hourly charge.

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
| [aws_route53_health_check.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_health_check.secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_health_check) | resource |
| [aws_route53_record.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53recoverycontrolconfig_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_cluster) | resource |
| [aws_route53recoverycontrolconfig_control_panel.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_control_panel) | resource |
| [aws_route53recoverycontrolconfig_routing_control.primary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_routing_control) | resource |
| [aws_route53recoverycontrolconfig_routing_control.secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_routing_control) | resource |
| [aws_route53recoverycontrolconfig_safety_rule.not_both_off](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_safety_rule) | resource |
| [aws_route53recoverycontrolconfig_safety_rule.not_both_on](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53recoverycontrolconfig_safety_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_primary_alb_dns_name"></a> [primary\_alb\_dns\_name](#input\_primary\_alb\_dns\_name) | DNS name of the primary (primary) ALB. | `string` | n/a | yes |
| <a name="input_primary_alb_zone_id"></a> [primary\_alb\_zone\_id](#input\_primary\_alb\_zone\_id) | Canonical hosted zone ID of the primary (primary) ALB. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_record_name"></a> [record\_name](#input\_record\_name) | Fully qualified record name where the failover pair publishes the application. | `string` | n/a | yes |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Hosted zone ID of the delegated base-domain zone. | `string` | n/a | yes |
| <a name="input_secondary_alb_dns_name"></a> [secondary\_alb\_dns\_name](#input\_secondary\_alb\_dns\_name) | DNS name of the secondary ALB. | `string` | n/a | yes |
| <a name="input_secondary_alb_zone_id"></a> [secondary\_alb\_zone\_id](#input\_secondary\_alb\_zone\_id) | Canonical hosted zone ID of the secondary ALB. | `string` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
