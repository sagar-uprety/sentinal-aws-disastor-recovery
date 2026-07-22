# Two ARC routing controls (primary, dr) gate two Route53 failover records
# via RECOVERY_CONTROL health checks. RECOVERY_CONTROL health status reflects
# only the control's manual On/Off state, not real endpoint health -- that is
# what makes the DNS switch operator-gated rather than automatic. A plain
# Route53 failover policy driven by ALB health checks is deliberately not
# used here: it would auto-route to DR the moment prod's health check fails,
# including while DR is still at desired_count=0.
# Detection-only HTTP health checks for evidence/alarming live in the DR
# environment root so they remain active even when ARC is toggled off.

resource "aws_route53recoverycontrolconfig_cluster" "main" {
  name = "${var.project_name}-arc"
}

resource "aws_route53recoverycontrolconfig_control_panel" "main" {
  name        = "${var.project_name}-arc"
  cluster_arn = aws_route53recoverycontrolconfig_cluster.main.arn
}

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

# Two safety rules, not one: ATLEAST/threshold=1/inverted=false blocks a
# change that would leave fewer than 1 On (no both-off); ATLEAST/threshold=2/
# inverted=true blocks a change that would leave 2 or more On (no both-on).
# This is the standard AWS ARC "exactly one active" pattern.
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

resource "aws_route53recoverycontrolconfig_safety_rule" "not_both_on" {
  name              = "not-both-on"
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main.arn
  wait_period_ms    = 5000

  asserted_controls = [
    aws_route53recoverycontrolconfig_routing_control.primary.arn,
    aws_route53recoverycontrolconfig_routing_control.dr.arn,
  ]

  # inverted negates the whole assertion, not just ATLEAST->ATMOST: this
  # evaluates as "fewer than 2 are On" (threshold=2, inverted=true), i.e. at
  # most 1 On. threshold=1 here would evaluate as "zero are On" and block
  # every control from ever being turned on -- confirmed by hitting that
  # exact AWS-side rejection ("No routing controls can be On") on first apply.
  rule_config {
    type      = "ATLEAST"
    threshold = 2
    inverted  = true
  }
}

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

  set_identifier  = "primary"
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
