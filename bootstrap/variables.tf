variable "project" {
  description = "Short project name used for resource naming."
  type        = string
  default     = "sre-demo"
}

variable "region" {
  description = "AWS region for the state bucket (should match the main stack)."
  type        = string
  default     = "us-east-1"
}

variable "force_destroy" {
  description = "Allow the state bucket to be destroyed with objects in it (exercise only)."
  type        = bool
  default     = true
}

variable "dns_zone_name" {
  description = "Optional subdomain to host in Route 53 (e.g. incode.example.com). Delegate it by adding the name_servers output as NS records at the parent domain's DNS provider."
  type        = string
  default     = null
}
