resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "RDS security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet"
  subnet_ids = var.db_subnet_ids
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-${var.environment}-pg"
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-${var.environment}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# One stable address allows a promoted replica to become a Terraform-managed primary without replacement.
resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_354:Performance Insights uses the AWS-managed alias/aws/rds key (no per-key monthly fee) rather than a customer-managed key
  #checkov:skip=CKV_AWS_293:this is a demo project torn down and rebuilt frequently; deletion protection would block terraform destroy every time
  count = 1

  identifier = "${var.project_name}-${var.environment}"

  engine              = var.replicate_source_db_arn == null ? "postgres" : null
  engine_version      = var.replicate_source_db_arn == null ? var.engine_version : null
  instance_class      = var.instance_class
  replicate_source_db = var.replicate_source_db_arn
  kms_key_id          = var.kms_key_id

  db_name  = var.replicate_source_db_arn == null ? var.db_name : null
  username = var.replicate_source_db_arn == null ? var.username : null

  password_wo         = var.replicate_source_db_arn == null ? var.password_wo : null
  password_wo_version = var.replicate_source_db_arn == null ? var.password_wo_version : null

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  allocated_storage   = var.replicate_source_db_arn == null ? 20 : null
  storage_type        = "gp3"
  storage_encrypted   = true
  port                = 5432
  publicly_accessible = false
  multi_az            = var.multi_az
  apply_immediately   = true

  backup_retention_period = 7
  backup_window           = var.replicate_source_db_arn == null ? "03:00-04:00" : null
  maintenance_window      = var.replicate_source_db_arn == null ? "sun:04:00-sun:05:00" : null
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  # This is a demo project torn down and rebuilt frequently; deletion
  # protection would just get in the way of terraform destroy every time.
  deletion_protection                 = false
  skip_final_snapshot                 = true
  delete_automated_backups            = true
  iam_database_authentication_enabled = var.replicate_source_db_arn == null ? true : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Replicas inherit credentials. Promotion must not rotate them when write-only version state is absent.
  lifecycle {
    ignore_changes = [password_wo, password_wo_version]
  }
}

check "replica_encryption_key" {
  assert {
    condition     = var.replicate_source_db_arn == null || var.kms_key_id != null
    error_message = "kms_key_id is required for an encrypted cross-Region read replica."
  }
}
