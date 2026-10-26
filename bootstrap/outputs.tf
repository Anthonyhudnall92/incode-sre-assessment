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
