output "sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify."
  value       = aws_sns_topic.alerts.arn
}
