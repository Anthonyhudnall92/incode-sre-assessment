output "kms_key_arn" {
  value = aws_kms_key.observability.arn
}

output "application_log_group_name" {
  value = aws_cloudwatch_log_group.container_insights["application"].name
}

output "container_log_group_arns" {
  value = [for g in aws_cloudwatch_log_group.container_insights : g.arn]
}
