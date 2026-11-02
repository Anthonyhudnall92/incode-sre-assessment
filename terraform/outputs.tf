output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_cluster.cluster_name} --kubeconfig .kube/config"
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "database_subnet_cidrs" {
  value = module.network.database_subnet_cidrs
}

output "app_name" {
  value = var.app_name
}

output "app_namespace" {
  value = var.app_namespace
}

output "app_role_arn" {
  description = "IRSA role assumed by the app's ServiceAccount."
  value       = module.app_platform.app_role_arn
}

output "ecr_repository_url" {
  value = module.app_platform.ecr_repository_url
}

output "db_host" {
  value = module.database.address
}

output "db_port" {
  value = module.database.port
}

output "db_name" {
  value = var.db_name
}

output "db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials (the value never touches Terraform state)."
  value       = module.database.master_user_secret_arn
}

output "waf_web_acl_arn" {
  value = module.app_platform.waf_web_acl_arn
}

output "certificate_arn" {
  value = module.app_platform.certificate_arn
}

output "domain_name" {
  value = var.domain_name
}

output "route53_zone_id" {
  value = var.route53_zone_id
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}

output "dashboard_url" {
  value = module.observability.dashboard_url
}

output "external_dns_role_arn" {
  description = "IAM role for ExternalDNS, or empty when no domain is configured."
  value       = module.app_platform.external_dns_role_arn
}

output "cluster_endpoint" {
  description = "EKS API endpoint. Private by default: reach it with `make tunnel`."
  value       = module.eks_cluster.cluster_endpoint
}

output "jump_host_instance_id" {
  value = module.jump_host.instance_id
}
