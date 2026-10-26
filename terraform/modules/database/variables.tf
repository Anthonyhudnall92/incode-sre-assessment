variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "db_subnet_group_name" {
  type = string
}

variable "allowed_client_sg_ids" {
  description = "Security groups allowed to connect on 5432."
  type        = list(string)
}

variable "db_name" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "multi_az" {
  type = bool
}

variable "deletion_protection" {
  type = bool
}

variable "log_retention_days" {
  type = number
}

variable "logs_kms_key_arn" {
  description = "KMS key for CloudWatch log group encryption."
  type        = string
}
