data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  # API endpoint: private, reached through the SSM jump host
  # (api_client_security_groups). The public endpoint is break-glass only
  # (endpoint_public_access), and then only from admin_cidrs.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.endpoint_public_access ? var.admin_cidrs : null

  cluster_security_group_additional_rules = {
    for name, sg in var.api_client_security_groups : "api_from_${name}" => {
      description              = "Kubernetes API from ${name}"
      type                     = "ingress"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      source_security_group_id = sg
    }
  }

  # Access entries (no aws-auth ConfigMap). Admins are listed explicitly rather
  # than "whoever ran Terraform", so a CI apply cannot silently swap them.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    for name, arn in var.cluster_admins : name => {
      principal_arn = arn
      policy_associations = {
        cluster-admin = {
          policy_arn   = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  enable_irsa = true

  # Fixed role name (sre-demo-cluster) instead of a timestamped prefix.
  iam_role_use_name_prefix      = false
  iam_role_permissions_boundary = var.permissions_boundary_arn

  # Envelope-encrypt Kubernetes Secrets with a dedicated, rotating KMS key.
  create_kms_key          = true
  enable_kms_key_rotation = true
  # Explicit, for the same reason as access_entries. The default key policy
  # still delegates to IAM, so a CI role with KMS permissions can manage it.
  kms_key_administrators                    = values(var.cluster_admins)
  kms_key_deletion_window_in_days           = 7
  cluster_encryption_policy_name            = "${var.name}-cluster-encryption"
  cluster_encryption_policy_use_name_prefix = false
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # Control plane logs, including the audit log, to CloudWatch.
  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.logs_kms_key_arn

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # CNI gets its own IRSA role instead of borrowing the node role.
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      # Enforce Kubernetes NetworkPolicy natively in the VPC CNI, and hand
      # out /28 prefixes instead of single IPs, so a t3.medium can run 110
      # pods instead of 17 (see node_max_pods). Pod IPs still come from the
      # private subnets.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = var.node_ami_type
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Fixed role name. The node group and launch template keep their
      # generated names: they must change when the group is replaced.
      iam_role_name                 = "${var.name}-node"
      iam_role_use_name_prefix      = false
      iam_role_permissions_boundary = var.permissions_boundary_arn

      # The CNI policy lives on the vpc-cni IRSA role, not the node role.
      iam_role_attach_cni_policy = false

      # Session Manager instead of SSH: no key pairs, no port 22.
      iam_role_additional_policies = {
        ssm = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # IMDSv2 only. Hop limit 1 stops pods from reaching node credentials.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = var.node_imds_hop_limit
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Tell the kubelet about the larger pod capacity that prefix
      # delegation gives (AWS's figure for instance types under 30 vCPUs).
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: ${var.node_max_pods}
        EOT
      }]

      labels = {
        workload = "general"
      }
    }
  }
}

# --- IRSA roles for system components ------------------------------------------

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn
  policy_name_prefix            = "${var.name}-"

  role_name             = "${var.name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn
  policy_name_prefix            = "${var.name}-"

  role_name                              = "${var.name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "cloudwatch_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn
  policy_name_prefix            = "${var.name}-"

  role_name = "${var.name}-cloudwatch-agent"
  role_policy_arns = {
    cloudwatch = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
    }
  }
}

# --- AWS Load Balancer Controller ----------------------------------------------

# --- Container Insights add-on ----------------------------------------------------
# Metrics + Fluent Bit log shipping to CloudWatch. Kept out of the module's
# cluster_addons so it can wait for the pre-created log groups (KMS key and
# retention) with a resource-level depends_on. A module-level depends_on would
# defer every data source in this module whenever log storage changes, turning
# unrelated attributes "known after apply" and forcing needless replacements.

resource "terraform_data" "log_groups_ready" {
  input = var.container_log_group_arns
}

data "aws_eks_addon_version" "cloudwatch_observability" {
  addon_name         = "amazon-cloudwatch-observability"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = data.aws_eks_addon_version.cloudwatch_observability.version
  service_account_role_arn    = module.cloudwatch_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # After the nodes (it runs a DaemonSet) and after its log groups exist.
  depends_on = [module.eks, terraform_data.log_groups_ready]
}
