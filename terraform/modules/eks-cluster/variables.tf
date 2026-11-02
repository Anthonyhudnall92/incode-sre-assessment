variable "name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "cluster_admins" {
  description = "IAM principal ARNs keyed by a short name; each gets cluster-admin and KMS key administration."
  type        = map(string)
}

variable "admin_cidrs" {
  type = list(string)
}

variable "node_ami_type" {
  type = string
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_min_size" {
  type = number
}

variable "node_desired_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_imds_hop_limit" {
  type = number
}


variable "log_retention_days" {
  type = number
}

variable "logs_kms_key_arn" {
  description = "KMS key for CloudWatch log group encryption."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every IAM role this module creates."
  type        = string
}

variable "container_log_group_arns" {
  description = "Container Insights log groups that must exist before the CloudWatch add-on starts."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Open the public API endpoint (to admin_cidrs only). Break-glass: normally the API is private."
  type        = bool
}

variable "api_client_security_groups" {
  description = "Security groups allowed to reach the private API endpoint on 443, by name."
  type        = map(string)
  default     = {}
}

variable "node_max_pods" {
  description = "Pods per node. 110 needs VPC CNI prefix delegation (on); without it a t3.medium holds 17."
  type        = number
  default     = 110
}

variable "addon_versions" {
  description = "Exact EKS add-on versions. Bump them in a PR (aws eks describe-addon-versions) and review the plan."
  type        = map(string)
  default = {
    "vpc-cni"                         = "v1.23.2-eksbuild.8"
    "coredns"                         = "v1.13.2-eksbuild.62"
    "kube-proxy"                      = "v1.34.6-eksbuild.62"
    "amazon-cloudwatch-observability" = "v7.0.0-eksbuild.1"
  }
}
