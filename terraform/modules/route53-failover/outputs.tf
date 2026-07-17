output "cluster_arn" {
  description = "ARN of the ARC routing control cluster."
  value       = aws_route53recoverycontrolconfig_cluster.main.arn
}

output "primary_routing_control_arn" {
  description = "ARN of the primary routing control, toggled via the ARC data-plane API to switch traffic."
  value       = aws_route53recoverycontrolconfig_routing_control.primary.arn
}

output "dr_routing_control_arn" {
  description = "ARN of the DR routing control, toggled via the ARC data-plane API to switch traffic."
  value       = aws_route53recoverycontrolconfig_routing_control.dr.arn
}

output "primary_cluster_endpoints" {
  description = "ARC data-plane endpoints, needed to call update-routing-control-state / get-routing-control-state (control-plane calls use the regular AWS API; data-plane calls require one of these region-specific endpoints)."
  value       = aws_route53recoverycontrolconfig_cluster.main.cluster_endpoints
}
