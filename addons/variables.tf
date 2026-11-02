variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster created by the main stack (terraform/)."
  type        = string
  default     = "sre-demo"
}

variable "lb_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.13.0"
}
