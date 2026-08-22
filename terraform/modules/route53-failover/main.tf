# ARC's routing controls are on/off switches with no ALB knowledge of their own.
# each mirrors into its own Route53 health check below, which is what actually decides which
# ALB gets traffic.

resource "aws_route53recoverycontrolconfig_cluster" "main" {
  name = "${var.project_name}-arc"
}

resource "aws_route53recoverycontrolconfig_control_panel" "main" {
  name        = "${var.project_name}-arc"
  cluster_arn = aws_route53recoverycontrolconfig_cluster.main.arn
}

# Just an on/off switch, doesn't know an ALB or DNS record exists
resource "aws_route53recoverycontrolconfig_routing_control" "primary" {
  name              = "primary"
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.main.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main.arn
}

resource "aws_route53recoverycontrolconfig_routing_control" "dr" {
  name              = "dr"
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.main.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main.arn
}

# enforce at least 1 on
resource "aws_route53recoverycontrolconfig_safety_rule" "not_both_off" {
  name              = "not-both-off"
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main.arn
  wait_period_ms    = 5000

  asserted_controls = [
    aws_route53recoverycontrolconfig_routing_control.primary.arn,
    aws_route53recoverycontrolconfig_routing_control.dr.arn,
  ]

  rule_config {
    type      = "ATLEAST"
    threshold = 1
    inverted  = false
  }
}

# enforce at most 1 on
resource "aws_route53recoverycontrolconfig_safety_rule" "not_both_on" {
  name              = "not-both-on"
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main.arn
  wait_period_ms    = 5000

  asserted_controls = [
    aws_route53recoverycontrolconfig_routing_control.primary.arn,
    aws_route53recoverycontrolconfig_routing_control.dr.arn,
  ]

  # inverted negates the whole assertion: threshold=2 -> "fewer than 2 On" = at most 1.
  # threshold=1 would wrongly block all controls from ever turning on
  rule_config {
    type      = "ATLEAST"
    threshold = 2
    inverted  = true
  }
}

# Mirrors the linked routing control's On/Off state as healthy/unhealthy
resource "aws_route53_health_check" "primary" {
  type                = "RECOVERY_CONTROL"
  routing_control_arn = aws_route53recoverycontrolconfig_routing_control.primary.arn

  tags = {
    Name = "${var.project_name}-primary-routing-control"
  }
}

resource "aws_route53_health_check" "dr" {
  type                = "RECOVERY_CONTROL"
  routing_control_arn = aws_route53recoverycontrolconfig_routing_control.dr.arn

  tags = {
    Name = "${var.project_name}-dr-routing-control"
  }
}

resource "aws_route53_record" "primary" {
  zone_id = var.route53_zone_id
  name    = var.record_name
  type    = "A"

  set_identifier = "primary"
  # Route53's own failover engine reads this to decide primary vs dr
  health_check_id = aws_route53_health_check.primary.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = var.primary_alb_dns_name
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "dr" {
  zone_id = var.route53_zone_id
  name    = var.record_name
  type    = "A"

  set_identifier  = "dr"
  health_check_id = aws_route53_health_check.dr.id

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.dr_alb_dns_name
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = false
  }
}
