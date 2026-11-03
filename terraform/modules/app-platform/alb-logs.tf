# --- ALB access logs ------------------------------------------------------------
#
# WAF logs record what each request asked for and whether WAF let it through.
# The ALB's access log adds what happened next: the target that answered, the
# status code, processing times and the TLS version. The ALB itself belongs
# to the Load Balancer Controller; the Ingress turns logging on with this
# bucket (addons/ passes its name to the chart).

data "aws_caller_identity" "current" {}

# The AWS account that delivers load balancer logs in this region.
data "aws_elb_service_account" "current" {}

locals {
  alb_logs_prefix = "alb"
}

resource "aws_s3_bucket" "alb_logs" {
  # checkov:skip=CKV_AWS_18:Access logs of the access-log bucket would only log log delivery
  # checkov:skip=CKV_AWS_21:Logs are written once and expire; versioning adds nothing
  # checkov:skip=CKV_AWS_144:Cross-region replication of short-lived access logs is not worth the cost
  # checkov:skip=CKV_AWS_145:ALB log delivery supports SSE-S3 only, not SSE-KMS
  # checkov:skip=CKV2_AWS_62:Nothing consumes events from this bucket
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # exercise only: teardown is one command
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}

    expiration {
      days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  # Only the regional log-delivery account, only under this account's prefix.
  statement {
    sid       = "AlbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/${local.alb_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }
  }

  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
