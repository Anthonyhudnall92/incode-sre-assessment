output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "app_role_arn" {
  value = module.app_irsa.iam_role_arn
}

output "waf_web_acl_arn" {
  value = var.enable_waf ? aws_wafv2_web_acl.app[0].arn : ""
}

output "waf_web_acl_name" {
  value = var.enable_waf ? aws_wafv2_web_acl.app[0].name : ""
}

output "certificate_arn" {
  description = "Validated ACM certificate ARN, or empty when no domain is configured."
  value       = local.create_cert ? aws_acm_certificate_validation.app[0].certificate_arn : ""
}

output "external_dns_role_arn" {
  description = "IAM role for ExternalDNS, or empty when no domain is configured."
  value       = local.create_cert ? module.external_dns_irsa[0].iam_role_arn : ""
}
