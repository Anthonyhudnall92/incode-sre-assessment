variable "name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "region" {
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

variable "lb_controller_chart_version" {
  type = string
}

variable "log_retention_days" {
  type = number
}

variable "logs_kms_key_arn" {
  description = "KMS key for CloudWatch log group encryption."
  type        = string
}
