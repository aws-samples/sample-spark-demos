# Single RDS PostgreSQL instance carrying all SPARK API service databases
# (one DB per service, created by the DB init job). Standard PostgreSQL
# clients upstream (SQLAlchemy/asyncpg/alembic). pgvector ships with RDS
# PostgreSQL >= 15 and is activated per database by the DB init job.

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "this" {
  name        = "${var.name}-postgres"
  description = "PostgreSQL access from EKS"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# Keyed by static map keys so for_each works with apply-time unknown SG IDs.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS (${each.key})"
}

resource "aws_db_parameter_group" "this" {
  name   = var.name
  family = "postgres${var.engine_version}"

  parameter {
    name  = "rds.force_ssl"
    value = var.force_ssl ? "1" : "0"
  }

  tags = var.tags
}

# --- Observability plumbing ------------------------------------------------------

data "aws_partition" "current" {}

# Pre-created so retention and encryption are managed here and the groups
# disappear with the environment — RDS would otherwise create never-expiring,
# unmanaged log groups on first export. The instance depends on them so RDS
# never wins the creation race.
resource "aws_cloudwatch_log_group" "this" {
  # Same list as enabled_cloudwatch_logs_exports below (kept literal there
  # for the static checks); the instance postcondition pins them together.
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}/${each.key}"
  retention_in_days = var.cloudwatch_logs_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Enhanced Monitoring publishes OS metrics through this service role.
resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name = "${var.name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- Instance ----------------------------------------------------------------------

resource "aws_db_instance" "this" { # nosemgrep: aws-rds-multiaz-not-enabled
  # ^ single-AZ is the documented demo default (multi_az variable), see the checkov skip for CKV_AWS_157 below
  # Multi-AZ doubles the instance cost of a short-lived single-region demo;
  # the switch stays available (multi_az variable / *_RDS_MULTI_AZ).
  #checkov:skip=CKV_AWS_157: Single-AZ by default for demo cost; opt-in via the multi_az variable
  # Deletion protection would block the hands-off `make destroy` the demo is
  # built around; opt-in via the deletion_protection variable for longer-lived
  # environments.
  #checkov:skip=CKV_AWS_293: Hands-off demo teardown; opt-in via the deletion_protection variable
  # rds.force_ssl stays configurable (force_ssl variable, demo default off):
  # upstream DSNs do not consistently set sslmode — documented deviation in
  # the README; traffic never leaves the VPC.
  #checkov:skip=CKV2_AWS_69: In-VPC traffic only; rds.force_ssl is opt-in via the force_ssl variable because upstream DSNs omit sslmode (documented deviation)
  identifier = var.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  multi_az               = var.multi_az
  publicly_accessible    = false

  username = var.master_username
  password = var.master_password
  # Additive: IAM tokens become possible for operators/tools; the services
  # keep using their password credentials.
  iam_database_authentication_enabled = true

  # Observability: engine + upgrade logs to CloudWatch (encrypted log groups
  # above), Performance Insights (free 7-day tier) and Enhanced Monitoring.
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = var.kms_key_arn
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = one(aws_iam_role.monitoring[*].arn)

  # Demo lifecycle: fast teardown, no final snapshot, minimal backups.
  backup_retention_period    = 1
  copy_tags_to_snapshot      = true
  skip_final_snapshot        = true
  deletion_protection        = var.deletion_protection
  apply_immediately          = true
  auto_minor_version_upgrade = true

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy_attachment.monitoring]

  lifecycle {
    postcondition {
      condition     = toset(self.enabled_cloudwatch_logs_exports) == toset(keys(aws_cloudwatch_log_group.this))
      error_message = "enabled_cloudwatch_logs_exports and the pre-created log groups must list the same log types."
    }
  }
}
