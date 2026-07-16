data "aws_region" "current" {}

locals {
  namespace = "${var.project_name}-${var.environment}.internal"

  otel_collector_config       = file("${path.module}/files/otel-collector-config.yaml")
  prometheus_config           = templatefile("${path.module}/files/prometheus.yml.tpl", { namespace = local.namespace })
  grafana_datasource          = templatefile("${path.module}/files/grafana-datasource.yml.tpl", { namespace = local.namespace })
  grafana_dashboards_provider = file("${path.module}/files/grafana-dashboards-provider.yml")
  sentinel_dashboard_json     = file("${path.module}/files/sentinel-dashboard.json")
}

resource "aws_service_discovery_private_dns_namespace" "monitoring" {
  name = local.namespace
  vpc  = var.vpc_id
}

resource "aws_cloudwatch_log_group" "monitoring" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs has no AWS-managed default KMS option (unlike S3/RDS/SSM); a customer-managed key isn't worth the monthly cost here
  name              = "/ecs/${var.project_name}-${var.environment}-monitoring"
  retention_in_days = 365
}

# --- IAM ---

resource "aws_iam_role" "execution" {
  name = "${var.project_name}-${var.environment}-monitoring-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role used only by Grafana, for ECS Exec / SSM port-forward access (no public ALB path for the demo).
resource "aws_iam_role" "grafana_task" {
  name = "${var.project_name}-${var.environment}-grafana-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_exec" {
  #checkov:skip=CKV_AWS_290,CKV_AWS_355:ssmmessages channel actions do not support resource-level scoping, per Hard Rule 7
  name = "${var.project_name}-${var.environment}-grafana-exec-access"
  role = aws_iam_role.grafana_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# --- Security groups (chained: app -> otel-collector <- prometheus <- grafana) ---

resource "aws_security_group" "grafana" {
  name        = "${var.project_name}-${var.environment}-grafana-sg"
  description = "Grafana ECS task security group (accessed only via SSM port-forward, no inbound rule needed)"
  vpc_id      = var.vpc_id

  #checkov:skip=CKV_AWS_382:internal-only observability service reaching Prometheus, the OTel Collector, and AWS APIs (ECR, logs)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "prometheus" {
  name        = "${var.project_name}-${var.environment}-prometheus-sg"
  description = "Prometheus ECS task security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Query API from Grafana"
    from_port       = 9090
    to_port         = 9090
    protocol        = "tcp"
    security_groups = [aws_security_group.grafana.id]
  }

  #checkov:skip=CKV_AWS_382:internal-only observability service scraping the OTel Collector and reaching AWS APIs (ECR, logs)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "otel_collector" {
  name        = "${var.project_name}-${var.environment}-otel-collector-sg"
  description = "OTel Collector ECS task security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "OTLP HTTP from the Sentinel app"
    from_port       = 4318
    to_port         = 4318
    protocol        = "tcp"
    security_groups = [var.app_security_group_id]
  }

  ingress {
    description     = "Prometheus scrape from Prometheus"
    from_port       = 8889
    to_port         = 8889
    protocol        = "tcp"
    security_groups = [aws_security_group.prometheus.id]
  }

  #checkov:skip=CKV_AWS_382:internal-only observability service reaching AWS APIs (ECR, logs) only
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- OTel Collector ---

resource "aws_ecs_task_definition" "otel_collector" {
  family                   = "${var.project_name}-${var.environment}-otel-collector"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name    = "otel-collector"
      image   = "otel/opentelemetry-collector-contrib:0.116.1"
      command = ["--config=env:OTEL_CONFIG"]
      portMappings = [
        { containerPort = 4318, protocol = "tcp" },
        { containerPort = 8889, protocol = "tcp" },
      ]
      environment = [
        { name = "OTEL_CONFIG", value = local.otel_collector_config },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "otel-collector"
        }
      }
    }
  ])
}

resource "aws_service_discovery_service" "otel_collector" {
  name = "otel-collector"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.monitoring.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_ecs_service" "otel_collector" {
  name            = "${var.project_name}-${var.environment}-otel-collector"
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.otel_collector.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.otel_collector.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.otel_collector.arn
  }
}

# --- Prometheus ---

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "${var.project_name}-${var.environment}-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name       = "prometheus"
      image      = "prom/prometheus:v3.0.1"
      entryPoint = ["/bin/sh", "-c"]
      command = [
        <<-EOT
        cat <<'CONFIGEOF' > /etc/prometheus/prometheus.yml
        ${local.prometheus_config}
        CONFIGEOF
        exec /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=24h
        EOT
      ]
      portMappings = [
        { containerPort = 9090, protocol = "tcp" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "prometheus"
        }
      }
    }
  ])
}

resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.monitoring.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_ecs_service" "prometheus" {
  name            = "${var.project_name}-${var.environment}-prometheus"
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.prometheus.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.prometheus.arn
  }
}

# --- Grafana ---

resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.project_name}-${var.environment}-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.grafana_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name       = "grafana"
      image      = "grafana/grafana:11.4.0"
      entryPoint = ["/bin/sh", "-c"]
      command = [
        <<-EOT
        set -e
        mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
        cat <<'CONFIGEOF' > /etc/grafana/provisioning/datasources/prometheus.yml
        ${local.grafana_datasource}
        CONFIGEOF
        cat <<'CONFIGEOF' > /etc/grafana/provisioning/dashboards/dashboards.yml
        ${local.grafana_dashboards_provider}
        CONFIGEOF
        cat <<'CONFIGEOF' > /var/lib/grafana/dashboards/sentinel.json
        ${local.sentinel_dashboard_json}
        CONFIGEOF
        exec /run.sh
        EOT
      ]
      portMappings = [
        { containerPort = 3000, protocol = "tcp" },
      ]
      environment = [
        { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "true" },
        { name = "GF_AUTH_ANONYMOUS_ORG_ROLE", value = "Viewer" },
        { name = "GF_AUTH_DISABLE_LOGIN_FORM", value = "false" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "grafana" {
  name            = "${var.project_name}-${var.environment}-grafana"
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.grafana.id]
    assign_public_ip = false
  }
}
