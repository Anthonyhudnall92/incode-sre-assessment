variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "app_name" {
  type = string
}

variable "app_namespace" {
  type = string
}

variable "db_instance_identifier" {
  type = string
}

variable "alert_email" {
  type    = string
  default = null
}

variable "waf_web_acl_name" {
  description = "WAF web ACL name for the dashboard, or empty string when WAF is disabled."
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the alerts SNS topic."
  type        = string
}

variable "application_log_group_name" {
  description = "Container Insights application log group (source for log metric filters)."
  type        = string
}
