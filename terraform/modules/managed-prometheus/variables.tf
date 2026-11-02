variable "name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "permissions_boundary_arn" {
  type = string
}

variable "collector_namespace" {
  description = "Namespace of the ADOT collector (addons/)."
  type        = string
  default     = "observability"
}

variable "collector_service_account" {
  type    = string
  default = "adot-collector"
}
