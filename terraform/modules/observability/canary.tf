# -----------------------------------------------------------------------------
# External synthetic check (CloudWatch Synthetics)
#
# Everything else that watches the app runs inside the cluster or reads its
# logs, so it shares the cluster's fate. This canary runs outside the VPC and
# requests the public URL every 5 minutes, through internet -> WAF -> ALB ->
# app, like a visitor. It is created only when the app has a domain.
# -----------------------------------------------------------------------------

locals {
  canary = var.domain_name == null ? 0 : 1
  # Synthetics allows 21 lowercase characters.
  canary_name = "${var.name}-board"
}

data "aws_caller_identity" "current" {}

# --- Artifacts (screenshots-free: an API canary stores step results and logs) ---

resource "aws_s3_bucket" "canary" {
  # checkov:skip=CKV_AWS_18:Access logs for a bucket holding canary step results would only log the canary itself
  # checkov:skip=CKV_AWS_21:Run results are disposable and expire after 14 days; versioning adds nothing
  # checkov:skip=CKV_AWS_144:Cross-region replication of disposable canary results is not worth the cost
  # checkov:skip=CKV_AWS_145:SSE-S3 is enough: results hold status codes and timings of a public page, no bodies or headers
  # checkov:skip=CKV2_AWS_62:Nothing consumes events from this bucket
  count = local.canary

  bucket        = "${var.name}-canary-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # exercise only: teardown is one command
}

resource "aws_s3_bucket_public_access_block" "canary" {
  count  = local.canary
  bucket = aws_s3_bucket.canary[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "canary" {
  count  = local.canary
  bucket = aws_s3_bucket.canary[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary" {
  count  = local.canary
  bucket = aws_s3_bucket.canary[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "canary" {
  count  = local.canary
  bucket = aws_s3_bucket.canary[0].id

  rule {
    id     = "expire-runs"
    status = "Enabled"
    filter {}

    expiration {
      days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Execution role: write its own results, metrics and logs; nothing else ----

data "aws_iam_policy_document" "canary_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "canary" {
  count = local.canary

  name                 = "${var.name}-canary"
  description          = "CloudWatch Synthetics canary for the app's public URL"
  assume_role_policy   = data.aws_iam_policy_document.canary_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "canary" {
  count = local.canary

  statement {
    sid       = "WriteResults"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.canary[0].arn}/*"]
  }

  statement {
    sid       = "FindBucket"
    actions   = ["s3:GetBucketLocation", "s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CloudWatchSynthetics"]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/cwsyn-${local.canary_name}-*"]
  }
}

resource "aws_iam_role_policy" "canary" {
  count  = local.canary
  name   = "canary"
  role   = aws_iam_role.canary[0].id
  policy = data.aws_iam_policy_document.canary[0].json
}

# --- The canary -------------------------------------------------------------------

# The file name carries the script's hash: Synthetics only redeploys when
# zip_file changes, and a new path is how Terraform sees a new script.
data "archive_file" "canary" {
  type        = "zip"
  output_path = "${path.root}/.terraform/canary-${filemd5("${path.module}/canary/canary.js")}.zip"

  source {
    content  = file("${path.module}/canary/canary.js")
    filename = "nodejs/node_modules/canary.js"
  }
}

resource "aws_synthetics_canary" "board" {
  count = local.canary

  name                 = local.canary_name
  artifact_s3_location = "s3://${aws_s3_bucket.canary[0].bucket}/"
  execution_role_arn   = aws_iam_role.canary[0].arn
  runtime_version      = var.canary_runtime_version
  handler              = "canary.handler"
  zip_file             = data.archive_file.canary.output_path
  start_canary         = true
  delete_lambda        = true # remove its function and layers on destroy

  success_retention_period = 7
  failure_retention_period = 14

  schedule {
    expression = "rate(5 minutes)"
  }

  run_config {
    timeout_in_seconds = 60
    active_tracing     = false
    environment_variables = {
      BASE_URL = "https://${var.domain_name}"
    }
  }

  depends_on = [aws_iam_role_policy.canary]
}

# Pages when the public URL fails 2 of the last 3 runs. Missing data stays
# "missing", so creating the alarm does not page (it starts with no data);
# if the canary itself stops running, the alarm moves OK -> INSUFFICIENT_DATA,
# and that notifies too.
resource "aws_cloudwatch_metric_alarm" "external_down" {
  count = local.canary

  alarm_name          = "${var.name}-${var.app_name}-external-down"
  alarm_description   = "The public URL failed the external canary (internet -> WAF -> ALB -> app) in 2 of the last 3 runs. Checked from outside the VPC, so it still works if the cluster is down."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  dimensions          = { CanaryName = aws_synthetics_canary.board[0].name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  alarm_actions             = local.alarm_actions
  ok_actions                = local.alarm_actions
  insufficient_data_actions = local.alarm_actions
}
