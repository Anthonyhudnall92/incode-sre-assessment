data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "db_kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

# Customer-managed key for RDS storage and the RDS-managed master secret. The app role is granted kms:Decrypt via
# Secrets Manager only (see app-platform module).
resource "aws_kms_key" "db" {
  description             = "${var.name} RDS storage and master secret"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.db_kms.json
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.db.key_id
}

# Ingress only on 5432 and only from the EKS node security group.
# No egress rules: Terraform strips AWS's default allow-all egress, and RDS
# never needs to initiate connections.
resource "aws_security_group" "db" {
  name_prefix = "${var.name}-rds-"
  description = "PostgreSQL access from EKS workloads only"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.name}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_clients" {
  for_each = var.allowed_client_sg_ids

  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS nodes/pods"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg-"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "${var.name} PostgreSQL parameters"

  # Reject any non-TLS client connection (encryption in transit).
  # Static parameter: RDS records it as pending-reboot, so say so here or every
  # plan shows a change. (It is already in effect: the instance was created
  # with this parameter group.)
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "postgresql" {
  # Pre-create so retention is set (RDS would otherwise create it with "never expire").
  name              = "/aws/rds/instance/${var.name}/postgresql"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

# Enhanced monitoring (OS-level metrics every 60s).
data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  db_name  = var.db_name
  username = "dbadmin"

  # RDS generates the password and stores it in Secrets Manager (encrypted
  # with our CMK, rotated by RDS). It never appears in code or Terraform state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.key_id

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  port                   = 5432

  parameter_group_name = aws_db_parameter_group.this.name
  ca_cert_identifier   = "rds-ca-rsa2048-g1"

  multi_az                   = var.multi_az
  backup_retention_period    = 3
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-final" : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.monitoring.arn

  depends_on = [aws_cloudwatch_log_group.postgresql, aws_iam_role_policy_attachment.monitoring]
}
