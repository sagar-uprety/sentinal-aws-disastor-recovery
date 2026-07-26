resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:uses the AWS-managed default SNS key to avoid customer-managed-key fixed cost
  name = "${local.project_name}-${local.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "publishers" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "AllowCloudWatchPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "${local.project_name}-${local.environment}-alb-healthy-hosts"
  alarm_description   = "Isolated monitor ALB has no healthy target."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.deploy_service ? "breaching" : "notBreaching"

  dimensions = {
    LoadBalancer = module.alb.alb_arn_suffix
    TargetGroup  = module.alb.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "running_tasks" {
  alarm_name          = "${local.project_name}-${local.environment}-ecs-running-tasks"
  alarm_description   = "Isolated monitor ECS running task count is below one."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.deploy_service ? "breaching" : "notBreaching"

  dimensions = {
    ClusterName = module.service.cluster_name
    ServiceName = "${local.project_name}-${local.environment}"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_event_rule" "deployment_failed" {
  name        = "${local.project_name}-${local.environment}-ecs-deployment-failed"
  description = "Reports isolated monitor deployment circuit-breaker failures."

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Deployment State Change"]
    resources = [
      "arn:aws:ecs:${local.region}:${data.aws_caller_identity.current.account_id}:service/${local.project_name}-${local.environment}/${local.project_name}-${local.environment}",
    ]
    detail = {
      eventName = ["SERVICE_DEPLOYMENT_FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "deployment_failed" {
  rule = aws_cloudwatch_event_rule.deployment_failed.name
  arn  = aws_sns_topic.alerts.arn
}
