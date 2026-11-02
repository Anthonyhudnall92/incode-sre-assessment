# The Argo CD admin password: generated here, kept in Secrets Manager, and
# given to Argo CD only as a bcrypt hash. Nobody picks or types it; read it
# with `make argocd-password` (your IAM identity, logged by CloudTrail).
#
# Rotate:  terraform -chdir=addons apply -replace=random_password.argocd_admin
#
# The plaintext is also in this layer's state, which lives in the encrypted,
# private state bucket.

resource "random_password" "argocd_admin" {
  length      = 32
  special     = false # copy-paste friendly; 32 alphanumerics is ~190 bits
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

# Changes only when the password does, so Argo CD keeps sessions otherwise.
resource "time_static" "argocd_admin_set" {
  triggers = {
    password = random_password.argocd_admin.id
  }
}

# Explicit key policy: the account administers and uses the key through IAM,
# and Secrets Manager may use it only on behalf of callers in this account.
data "aws_iam_policy_document" "argocd_admin_key" {
  statement {
    sid       = "AccountAdministersThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "SecretsManagerOnly"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "argocd_admin" {
  description             = "Encrypts the Argo CD admin password secret"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.argocd_admin_key.json
}

resource "aws_kms_alias" "argocd_admin" {
  name          = "alias/${var.cluster_name}-argocd-admin"
  target_key_id = aws_kms_key.argocd_admin.key_id
}

resource "aws_secretsmanager_secret" "argocd_admin" {
  # checkov:skip=CKV2_AWS_57:Rotated by replacing random_password (see above); there is no Lambda to rotate an Argo CD local account
  name        = "${var.cluster_name}/argocd-admin"
  description = "Argo CD admin login (username admin)"
  kms_key_id  = aws_kms_key.argocd_admin.arn

  # Exercise only: allows a clean teardown and rebuild under the same name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id = aws_secretsmanager_secret.argocd_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.argocd_admin.result
  })
}
