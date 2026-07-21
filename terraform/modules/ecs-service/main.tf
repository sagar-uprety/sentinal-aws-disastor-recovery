data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

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
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
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

resource "aws_iam_role_policy" "rds_topology" {
  #checkov:skip=CKV_AWS_355:rds:DescribeDBInstances does not support resource-level permissions; the app only requests its configured identifier.
  name = "${var.project_name}-${var.environment}-rds-topology"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rds:DescribeDBInstances"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_topology" {
  #checkov:skip=CKV_AWS_355:ecs:ListTasks does not support service-level resource constraints; the app queries only its own cluster and service names.
  name = "${var.project_name}-${var.environment}-ecs-topology"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecs:DescribeServices",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_access" {
  name = "${var.project_name}-${var.environment}-ssm-access"
  role = aws_iam_role.task_execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = [var.db_password_ssm_arn]
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = [
          "arn:aws:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key/*"
        ]
      }
    ]
  })
}

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-${var.environment}-ecs-sg"
  description = "ECS tasks security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  #checkov:skip=CKV_AWS_382:sentinel is an uptime checker that probes arbitrary externally-configured target URLs (see TARGETS env var) plus AWS API endpoints (ECR, SSM, CloudWatch, RDS); it needs broad outbound by design
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs has no AWS-managed default KMS option (unlike S3/RDS/SSM); a customer-managed key is the only way to satisfy this and isn't worth the monthly cost here
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 365
}

resource "aws_ecs_task_definition" "app" {
  count = var.deploy_service ? 1 : 0

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

  container_definitions = jsonencode([
    {
      name  = "sentinel"
      image = var.image_uri
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "DB_HOST", value = split(":", var.db_endpoint)[0] },
        { name = "DB_PORT", value = split(":", var.db_endpoint)[1] },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USER", value = var.db_user },
        { name = "DB_INSTANCE_IDENTIFIER", value = var.db_instance_identifier },
        { name = "AWS_REGION", value = data.aws_region.current.region },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "CHECK_INTERVAL_SECONDS", value = "30" },
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.db_password_ssm_arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}-${var.environment}"
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "sentinel"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  count = var.deploy_service ? 1 : 0

  name            = "${var.project_name}-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app[0].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

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
    container_name   = "sentinel"
    container_port   = var.container_port
  }

  # Application CI/CD owns regional task definition promotion after initial creation.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [
    aws_iam_role_policy.ecs_topology,
    aws_iam_role_policy.ssm_access,
    aws_iam_role_policy.rds_topology,
    aws_iam_role_policy_attachment.task_execution,
  ]
}
