# -----------------------------------------------------------------------------
# Remote-state bootstrap
#
# Creates the S3 bucket + KMS key that hold the main stack's Terraform state.
# This stack itself uses LOCAL state (chicken-and-egg); its state file is
# gitignored and only contains non-secret bucket/key metadata.
#
# Locking uses S3 native lockfiles (Terraform >= 1.10, `use_lockfile = true`),
# so no DynamoDB table is required.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

data "aws_iam_policy_document" "state_kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform remote state for ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.state_kms.json
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_18:Access logging would need a second bucket; CloudTrail data events are the production answer (README TODO)
  # checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a single-region exercise
  # checkov:skip=CKV2_AWS_62:No consumers for state-bucket event notifications
  bucket = local.bucket_name

  # Allows `terraform destroy` of this bootstrap stack after the exercise.
  # Set to false for anything long-lived.
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Deny any non-TLS access and any unencrypted / wrong-key uploads.
data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

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

  statement {
    sid       = "DenyWrongKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# DNS: delegated subdomain for the app
#
# Lives here, not in the main stack, so `make down` never destroys it. A new
# zone gets new name servers, which would mean redoing the NS delegation at
# the parent domain's DNS provider. The parent domain stays where it is; only
# this subdomain is delegated, so the account can only issue certificates for
# and change records under it.
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "app" {
  # checkov:skip=CKV2_AWS_38:DNSSEC would also need a DS record at the parent; parent zone is unsigned (README exception)
  # checkov:skip=CKV2_AWS_39:Query logging out of scope for a demo zone (README exception)
  count = var.dns_zone_name == null ? 0 : 1

  name    = var.dns_zone_name
  comment = "Delegated from the parent domain; long-lived, outside the main stack"

  # Refuse to delete while the main stack's records still exist.
  force_destroy = false
}
