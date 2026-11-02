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
