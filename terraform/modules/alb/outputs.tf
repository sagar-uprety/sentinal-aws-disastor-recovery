output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the ALB, for Route53 alias records."
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "ARN of the ALB target group."
  value       = aws_lb_target_group.app.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch alarm dimensions."
  value       = aws_lb.main.arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the ALB target group, for CloudWatch alarm dimensions."
  value       = aws_lb_target_group.app.arn_suffix
}

output "security_group_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}
