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

resource "aws_iam_role_policy" "ssm_access" {
  name = "${var.project_name}-${var.environment}-ssm-access"
  role = aws_iam_role.task_execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameters"]
        Resource = [
          var.db_password_ssm_arn,
          var.link_create_token_ssm_arn,
        ]
      },
      # SSM parameters above are encrypted with the AWS-managed alias/aws/ssm key,
      # whose actual key ID isn't a stable ARN this policy can reference directly.
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

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 365
}

# Gated by deploy_service for the two-phase apply: a foundation apply
# (deploy_service=false) creates the ECR repo first so an image can be built
# and pushed before this task definition tries to reference its digest.
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
      name  = local.container_name
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
        { name = "PORT", value = tostring(var.container_port) },
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.db_password_ssm_arn
        },
        {
          name      = "LINK_CREATE_TOKEN"
          valueFrom = var.link_create_token_ssm_arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "shortener"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  count = var.deploy_service ? 1 : 0

  name             = "${var.project_name}-${var.environment}"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app[0].arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

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

  # Application CI/CD owns regional task definition promotion after initial creation.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [
    aws_iam_role_policy.ssm_access,
    aws_iam_role_policy_attachment.task_execution,
  ]
}
