variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "app_name" {
  type = string
}

variable "app_namespace" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "db_kms_key_arn" {
  type = string
}

variable "enable_waf" {
  type = bool
}

variable "domain_name" {
  type    = string
  default = null
}

variable "route53_zone_id" {
  type    = string
  default = null
}

variable "log_retention_days" {
  type = number
}

variable "logs_kms_key_arn" {
  description = "KMS key for CloudWatch log group encryption."
  type        = string
}
