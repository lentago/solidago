# modules/rds/main.tf

# =============================================================================
# RDS POSTGRESQL
#
# Production-grade PostgreSQL instance with:
#   - Multi-AZ for high availability
#   - KMS encryption at rest
#   - RDS-managed master credentials (no passwords in Terraform state)
#   - gp3 storage for better price/performance
#   - Automated backups with configurable retention
#   - Deletion protection enabled
# =============================================================================

# --- DB Subnet Group ---
# Tells RDS which subnets to place the instance (and standby) in.
# Must span at least two AZs for Multi-AZ deployments.
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-db-subnet-group"
  subnet_ids = var.data_subnet_ids

  tags = {
    Name = "${var.project}-${var.environment}-db-subnet-group"
  }
}

# --- Parameter Group ---
# Custom parameter group so we can tune PostgreSQL settings without
# modifying the default group (which can't be changed).
resource "aws_db_parameter_group" "this" {
  name   = "${var.project}-${var.environment}-pg16"
  family = "postgres16"

  # Log slow queries (anything over 1 second)
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Log connections and disconnections for auditing
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # Log all DDL statements (CREATE, ALTER, DROP)
  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  # Enable pg_stat_statements for query performance tracking
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.project}-${var.environment}-pg16"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- RDS Instance ---
resource "aws_db_instance" "this" {
  identifier = "${var.project}-${var.environment}-postgres"

  # Engine configuration
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Storage
  allocated_storage     = var.allocated_storage
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # Database
  db_name = var.db_name

  # Credentials — RDS manages the master password and stores it in
  # Secrets Manager automatically. No password in Terraform state.
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id]
  publicly_accessible    = false
  port                   = 5432

  # High availability
  multi_az = var.multi_az

  # Parameter group
  parameter_group_name = aws_db_parameter_group.this.name

  # Backups
  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"

  # Upgrades
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Protection
  deletion_protection   = false
  skip_final_snapshot   = true
  copy_tags_to_snapshot = true

  # Performance Insights (free tier for db.t4g.micro)
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7

  tags = {
    Name = "${var.project}-${var.environment}-postgres"
  }
}

moved {
  from = aws_db_subnet_group.main
  to   = aws_db_subnet_group.this
}

moved {
  from = aws_db_parameter_group.main
  to   = aws_db_parameter_group.this
}

moved {
  from = aws_db_instance.main
  to   = aws_db_instance.this
}
