data "aws_region" "current" {}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-${var.environment}-ecs-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${var.project_name}-${var.environment}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "runtime" {
  name = "${var.project_name}-${var.environment}-runtime"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MonitorData"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:PutItem",
          "dynamodb:Query",
        ]
        Resource = var.dynamodb_table_arn
      },
      {
        Sid    = "ReadWorkloadTopology"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "rds:DescribeDBInstances",
        ]
        # These describe actions are not resource-restrictable.
        #checkov:skip=CKV_AWS_355
        Resource = "*"
      },
    ]
  })
}

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-${var.environment}-ecs-sg"
  description = "Isolated sentry ECS tasks security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from sentry ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    description = "HTTPS and DNS through the VPC egress path"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 365
}

# Gated by deploy_service for the two-phase apply: a foundation apply (deploy_service=false)
# creates the ECR repo first, so an image exists before this references its digest.
resource "aws_ecs_task_definition" "main" {
  count = var.deploy_service ? 1 : 0

  # Application CI/CD registers new revisions directly; without this, an unrelated
  # apply would re-register a stale revision from the SSM digest at bootstrap time.
  track_latest = true

  family                   = "${var.project_name}-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = local.container_name
    image     = var.image_uri
    essential = true
    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]
    environment = [
      { name = "AWS_REGION", value = data.aws_region.current.region },
      { name = "CHECK_INTERVAL_SECONDS", value = "30" },
      { name = "SECONDARY_AWS_REGION", value = var.secondary_region },
      { name = "SECONDARY_DB_IDENTIFIER", value = var.secondary_database_identifier },
      { name = "SECONDARY_ECS_CLUSTER", value = var.secondary_ecs_cluster },
      { name = "SECONDARY_ECS_SERVICE", value = var.secondary_ecs_service },
      { name = "DYNAMODB_TABLE", value = var.dynamodb_table_name },
      { name = "MONITORED_URL", value = var.monitored_url },
      { name = "PORT", value = tostring(var.container_port) },
      { name = "PRIMARY_AWS_REGION", value = var.primary_region },
      { name = "PRIMARY_DB_IDENTIFIER", value = var.primary_database_identifier },
      { name = "PRIMARY_ECS_CLUSTER", value = var.primary_ecs_cluster },
      { name = "PRIMARY_ECS_SERVICE", value = var.primary_ecs_service },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.main.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "sentry"
      }
    }
  }])
}

resource "aws_ecs_service" "main" {
  count = var.deploy_service ? 1 : 0

  name            = "${var.project_name}-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main[0].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  # Pinned so observer behavior does not drift when AWS advances what LATEST points to.
  #checkov:skip=CKV_AWS_332
  platform_version      = "1.4.0"
  wait_for_steady_state = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # ecs-sentry.yml owns regional task definition promotion after initial creation.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [
    aws_iam_role_policy.runtime,
    aws_iam_role_policy_attachment.task_execution,
  ]
}
