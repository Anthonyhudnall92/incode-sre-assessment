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

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_apply_subject" {
  description = "OIDC subject (after repo:<owner>/<name>:) allowed to assume the apply role. \"environment:production\" requires a GitHub environment, which private repositories only get on paid plans; use \"ref:refs/heads/main\" until the repository is public."
  type        = string
  default     = "environment:production"
}

variable "ci_role_test_principals" {
  description = "IAM ARNs allowed to assume the CI roles directly, to test their permissions locally. Keep empty except while testing."
  type        = list(string)
  default     = []
}
