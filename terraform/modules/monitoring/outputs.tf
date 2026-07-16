output "otel_collector_endpoint" {
  description = "OTLP HTTP endpoint the Sentinel app should push metrics to."
  value       = "http://otel-collector.${local.namespace}:4318"
}

output "grafana_service_name" {
  description = "ECS service name for Grafana, used with `aws ecs execute-command` / SSM port-forward to reach the dashboard."
  value       = aws_ecs_service.grafana.name
}

output "namespace" {
  description = "Cloud Map private DNS namespace used for service-to-service discovery."
  value       = local.namespace
}

output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = aws_sns_topic.alerts.arn
}
