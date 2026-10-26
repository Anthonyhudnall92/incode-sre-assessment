variable "name" {
  type = string
}

variable "cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name, used for subnet discovery tags."
  type        = string
}

variable "single_nat_gateway" {
  type = bool
}

variable "log_retention_days" {
  type = number
}

variable "logs_kms_key_arn" {
  description = "KMS key for CloudWatch log group encryption."
  type        = string
}
