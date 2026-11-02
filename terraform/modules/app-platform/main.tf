locals {
  create_cert = var.domain_name != null && var.route53_zone_id != null
}

# --- Container registry ---------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "${var.name}/${var.app_name}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # exercise only, so teardown is one command

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- Workload identity (IRSA) ----------------------------------------------------
# The app can read exactly one secret, and decrypt it only through
# Secrets Manager. Nothing else in AWS.

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid       = "DecryptDatabaseSecretViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [var.db_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "app" {
  name        = "${var.name}-${var.app_name}-db-secret-read"
  description = "Least-privilege access for ${var.app_name} to its database secret"
  policy      = data.aws_iam_policy_document.app.json
}

module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn

  role_name = "${var.name}-${var.app_name}"
  role_policy_arns = {
    app = aws_iam_policy.app.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.app_namespace}:${var.app_name}"]
    }
  }
}

# --- ExternalDNS (optional) -------------------------------------------------------
# Points the app's domain at whichever ALB currently serves its Ingress. The
# role can change records in the app zone only.

module "external_dns_irsa" {
  count   = local.create_cert ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn
  policy_name_prefix            = "${var.name}-"

  role_name                     = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

# --- TLS certificate (optional) ----------------------------------------------------

resource "aws_acm_certificate" "app" {
  count = local.create_cert ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.create_cert ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count = local.create_cert ? 1 : 0

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --- WAF (defense in depth) --------------------------------------------------------
# Attached to the ALB by the Ingress annotation alb.ingress.kubernetes.io/wafv2-acl-arn.

resource "aws_wafv2_web_acl" "app" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.name}-${var.app_name}"
  description = "Managed protections and per-IP rate limiting for ${var.app_name}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common-rule-set"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 30

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000 # requests per 5 minutes per IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "per-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-${var.app_name}"
    sampled_requests_enabled   = true
  }
}

# WAF logs require a log group whose name starts with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${var.name}-${var.app_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.app[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Never log credentials or session cookies.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
