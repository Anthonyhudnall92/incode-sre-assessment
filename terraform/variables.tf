# --- General -------------------------------------------------------------------

variable "project" {
  description = "Short project name used for resource naming and tags."
  type        = string
  default     = "sre-demo"
}

variable "environment" {
  description = "Environment name (demo, dev, prod, ...)."
  type        = string
  default     = "demo"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "log_retention_days" {
  description = "Retention for CloudWatch log groups created by this stack."
  type        = number
  default     = 14
}

# --- Network -------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to span (EKS requires at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheap) instead of one per AZ (HA). Documented cost exception."
  type        = bool
  default     = true
}

# --- EKS -----------------------------------------------------------------------

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (e.g. your workstation /32). Never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "admin_cidrs must be a non-empty list of valid CIDRs and must not contain 0.0.0.0/0."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Pick one in standard support (aws eks describe-cluster-versions) to avoid extended-support charges."
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Graviton (arm64) is the cheapest option; the app image is built for linux/arm64."
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_imds_hop_limit" {
  description = "IMDSv2 hop limit on nodes. 1 blocks pods from reaching the node role via IMDS (preferred)."
  type        = number
  default     = 1
}

variable "lb_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.13.0"
}

# --- Database ------------------------------------------------------------------

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "demo"
}

variable "db_engine_version" {
  description = "PostgreSQL major (or major.minor) version."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ RDS. Off by default for cost (documented exception)."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Enable for anything long-lived. Off so the exercise can be torn down."
  type        = bool
  default     = false
}

# --- Application / edge --------------------------------------------------------

variable "app_name" {
  type    = string
  default = "demo-app"
}

variable "app_namespace" {
  type    = string
  default = "demo"
}

variable "domain_name" {
  description = "Optional FQDN for the app (e.g. demo.example.com). When set with route53_zone_id, an ACM cert is issued and the ALB serves HTTPS only (HTTP redirects)."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Hosted zone ID that owns domain_name (for ACM DNS validation and the app record)."
  type        = string
  default     = null
}

variable "enable_waf" {
  description = "Attach an AWS WAFv2 web ACL (managed rule groups + rate limit) to the ALB."
  type        = bool
  default     = true
}

# --- Observability -------------------------------------------------------------

variable "alert_email" {
  description = "Optional email subscribed to the alerts SNS topic (confirmation email required)."
  type        = string
  default     = null
}
