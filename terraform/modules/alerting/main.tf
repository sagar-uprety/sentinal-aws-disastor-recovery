data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  # Email scanners pre-fetch the unsubscribe link and can silently unsubscribe it; confirm manually via
  # `aws sns confirm-subscription --token <token> --authenticate-on-unsubscribe true`, not the emailed link.
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
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AllowCloudWatchAlarmsPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

# --- CloudWatch alarms ---

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  alarm_description   = "ALB target 5xx responses in the last minute."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60 # seconds
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
  alarm_name = "${var.project_name}-${var.environment}-alb-healthy-hosts"
  alarm_description = (
    var.ecs_desired_count == 0
    ? "DR ALB standby expects zero healthy targets."
    : "ALB has fewer than 1 healthy target."
  )
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60 # seconds
  evaluation_periods  = 2
  threshold           = var.ecs_desired_count == 0 ? 0 : 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.ecs_desired_count == 0 ? "notBreaching" : "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  alarm_name          = "${var.project_name}-${var.environment}-ecs-running-tasks"
  alarm_description   = "ECS running task count is below the desired count."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60 # seconds
  evaluation_periods  = 2
  threshold           = var.ecs_desired_count
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.ecs_desired_count == 0 ? "notBreaching" : "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.create_rds_alarms ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-rds-cpu"
  alarm_description   = "RDS CPU utilization above 80 percent."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300 # seconds
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.create_rds_alarms ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-rds-free-storage"
  alarm_description   = "RDS free storage below 2 GiB (10 percent of the provisioned 20 GB gp3 volume)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300 # seconds
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- EventBridge: ECS deployment circuit breaker rollback visibility ---

resource "aws_cloudwatch_event_rule" "ecs_deployment_failed" {
  name        = "${var.project_name}-${var.environment}-ecs-deployment-failed"
  description = "Fires when the ECS deployment circuit breaker rolls back a failed deployment."

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Deployment State Change"]
    detail = {
      eventName = ["SERVICE_DEPLOYMENT_FAILED"]
    }
    resources = local.deployment_failed_service_arns
  })
}

resource "aws_cloudwatch_event_target" "ecs_deployment_failed_sns" {
  rule = aws_cloudwatch_event_rule.ecs_deployment_failed.name
  arn  = aws_sns_topic.alerts.arn
}
