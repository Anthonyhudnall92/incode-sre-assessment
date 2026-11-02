output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

# Paste into terraform/backend.hcl (gitignored), or run `make backend-config`.
output "backend_hcl" {
  value = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "${var.project}/main.tfstate"
    region       = "${var.region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}

output "dns_zone_id" {
  description = "Set as route53_zone_id in terraform/terraform.tfvars."
  value       = one(aws_route53_zone.app[*].zone_id)
}

output "dns_name_servers" {
  description = "Add each as an NS record for the subdomain at the parent domain's DNS provider."
  value       = one(aws_route53_zone.app[*].name_servers)
}

output "github_plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github_apply.arn
}

output "workload_boundary_arn" {
  value = aws_iam_policy.workload_boundary.arn
}
