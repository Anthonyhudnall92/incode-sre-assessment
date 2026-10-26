data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Created BEFORE the EKS cluster (root module depends_on) so the CloudWatch
# Observability add-on finds these log groups already in place, with
# retention and KMS encryption, instead of creating them as "never expire".

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  ci_log_groups = toset(["application", "dataplane", "host", "performance"])
}

# --- KMS key for alert topic + all log groups in this stack -----------------------------------------

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch alarms must be able to publish to the encrypted topic.
  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }

  statement {
    sid = "CloudWatchLogsEncrypt"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "observability" {
  description             = "${var.name} alerts topic and container log groups"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "observability" {
  name          = "alias/${var.name}-observability"
  target_key_id = aws_kms_key.observability.key_id
}

# --- Container Insights log groups --------------------------------------------------

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.ci_log_groups

  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.observability.arn
}

