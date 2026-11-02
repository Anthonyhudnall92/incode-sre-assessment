variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster created by the main stack (terraform/). Also the prefix of its state key."
  type        = string
  default     = "sre-demo"
}

variable "api_server_url" {
  description = "Where to reach the Kubernetes API, e.g. https://127.0.0.1:8443 through `make tunnel`. Defaults to the cluster endpoint (only reachable when the public endpoint is on)."
  type        = string
  default     = null
}

variable "state_bucket" {
  description = "Bucket holding the main stack's state. Defaults to the name bootstrap/ gives it."
  type        = string
  default     = null
}

variable "repo_url" {
  description = "Git repository Argo CD deploys the app from. Public, so Argo CD needs no credentials."
  type        = string
  default     = "https://github.com/Anthonyhudnall92/incode-sre-assessment.git"
}

variable "repo_revision" {
  description = "Branch Argo CD follows. Merging to it is the release."
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.11.6"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.7"
}

variable "lb_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.13.0"
}

variable "external_dns_chart_version" {
  type    = string
  default = "1.23.0"
}
