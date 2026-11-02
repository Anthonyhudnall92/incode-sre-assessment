data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    # The CI apply role's KMS and ACM permissions are scoped to this tag
    # (bootstrap/github-oidc.tf), which keeps it away from bootstrap resources.
    Stack = "main"
  }
}

# Created by the bootstrap layer. Every IAM role in this stack carries it, and
# the CI apply role can only create roles that do.
data "aws_iam_policy" "workload_boundary" {
  name = "${local.name}-workload-boundary"
}

# Account-level guardrail: every new EBS volume in this region is encrypted,
# including ones created outside Terraform (e.g. by the EBS CSI driver).
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# KMS key for every log group + the Container Insights log groups. Must exist
# before the cluster's CloudWatch add-on starts shipping logs (container_log_group_arns).
module "log_storage" {
  source = "./modules/log-storage"

  name               = local.name
  region             = var.region
  cluster_name       = local.name
  log_retention_days = var.log_retention_days
}

module "network" {
  source = "./modules/network"

  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  name               = local.name
  cidr               = var.vpc_cidr
  azs                = local.azs
  cluster_name       = local.name
  single_nat_gateway = var.single_nat_gateway
  log_retention_days = var.log_retention_days
  logs_kms_key_arn   = module.log_storage.kms_key_arn
}

module "eks_cluster" {
  source = "./modules/eks-cluster"

  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  cluster_admins = var.cluster_admins

  name                   = local.name
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  admin_cidrs            = var.admin_cidrs
  endpoint_public_access = var.eks_public_access
  api_client_security_groups = {
    jump_host = module.jump_host.security_group_id
  }
  node_ami_type            = var.node_ami_type
  node_instance_types      = var.node_instance_types
  node_min_size            = var.node_min_size
  node_desired_size        = var.node_desired_size
  node_max_size            = var.node_max_size
  node_imds_hop_limit      = var.node_imds_hop_limit
  log_retention_days       = var.log_retention_days
  logs_kms_key_arn         = module.log_storage.kms_key_arn
  container_log_group_arns = module.log_storage.container_log_group_arns
}

module "database" {
  source = "./modules/database"

  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  name                  = local.name
  vpc_id                = module.network.vpc_id
  db_subnet_group_name  = module.network.database_subnet_group_name
  allowed_client_sg_ids = { eks_nodes = module.eks_cluster.node_security_group_id }
  db_name               = var.db_name
  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  multi_az              = var.db_multi_az
  deletion_protection   = var.db_deletion_protection
  log_retention_days    = var.log_retention_days
  logs_kms_key_arn      = module.log_storage.kms_key_arn
}

module "jump_host" {
  source = "./modules/jump-host"

  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  name      = local.name
  vpc_id    = module.network.vpc_id
  subnet_id = module.network.private_subnet_ids[0]
}

module "app_platform" {
  source = "./modules/app-platform"

  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  name               = local.name
  region             = var.region
  app_name           = var.app_name
  app_namespace      = var.app_namespace
  oidc_provider_arn  = module.eks_cluster.oidc_provider_arn
  db_secret_arn      = module.database.master_user_secret_arn
  db_kms_key_arn     = module.database.kms_key_arn
  enable_waf         = var.enable_waf
  domain_name        = var.domain_name
  route53_zone_id    = var.route53_zone_id
  log_retention_days = var.log_retention_days
  logs_kms_key_arn   = module.log_storage.kms_key_arn
}

module "observability" {
  source = "./modules/observability"

  name                   = local.name
  region                 = var.region
  cluster_name           = module.eks_cluster.cluster_name
  app_name               = var.app_name
  app_namespace          = var.app_namespace
  db_instance_identifier = module.database.instance_identifier
  alert_email            = var.alert_email
  waf_web_acl_name       = module.app_platform.waf_web_acl_name

  kms_key_arn                = module.log_storage.kms_key_arn
  application_log_group_name = module.log_storage.application_log_group_name
}

moved {
  from = module.eks_cluster.module.eks.aws_eks_addon.this["amazon-cloudwatch-observability"]
  to   = module.eks_cluster.aws_eks_addon.cloudwatch_observability
}
