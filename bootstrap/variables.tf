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
