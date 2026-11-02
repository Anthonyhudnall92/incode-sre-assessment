output "workspace_arn" {
  value = aws_prometheus_workspace.this.arn
}

output "remote_write_url" {
  value = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "query_url" {
  value = aws_prometheus_workspace.this.prometheus_endpoint
}

output "collector_role_arn" {
  value = module.collector_irsa.iam_role_arn
}
