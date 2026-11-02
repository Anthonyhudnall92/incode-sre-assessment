# -----------------------------------------------------------------------------
# GitHub Actions -> AWS, with no stored credentials
#
# GitHub issues each workflow run a short-lived OIDC token. AWS trusts that
# issuer and exchanges the token for 1-hour credentials on one of two roles:
#
#   sre-demo-github-plan    read-only; pull requests and main in this repository
#   sre-demo-github-apply   changes the main stack; only the approved subject
#                           (the `production` environment once the repo is
#                           public, `main` until then; see var.github_apply_subject)
#
# The apply role is scoped to the services and resource names the main stack
# uses. Every role it creates must carry sre-demo-workload-boundary, so it
# cannot mint a role more powerful than the workloads need. It cannot touch
# this bootstrap layer: the state bucket and key, the DNS zone, the boundary,
# or these CI roles.
# -----------------------------------------------------------------------------

locals {
  # The start of every OIDC subject from this repository. With immutable
  # subjects GitHub appends the owner and repository IDs to the names.
  github_owner      = split("/", var.github_repository)[0]
  github_repo_name  = split("/", var.github_repository)[1]
  github_sub_prefix = var.github_repository_id == null ? "repo:${var.github_repository}" : "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo_name}@${var.github_repository_id}"

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  arn_prefix = "arn:${local.partition}"

  # Main-stack name and the tag that marks its resources (terraform/main.tf).
  stack = var.project
  stack_tag = {
    key   = "Stack"
    value = "main"
  }

  github_oidc_host = "token.actions.githubusercontent.com"
  boundary_arn     = "${local.arn_prefix}:iam::${local.account_id}:policy/${local.stack}-workload-boundary"
  state_key        = "${var.project}/main.tfstate"
  zone_arn         = "${local.arn_prefix}:route53:::hostedzone/${one(aws_route53_zone.app[*].zone_id)}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Permissions boundary for every role the main stack creates ----------------
# The most any workload or controller role can ever do, whatever policies are
# attached to it. No IAM writes (except service-linked roles the controllers
# need), no S3, nothing on the state key.

data "aws_iam_policy_document" "workload_boundary" {
  # checkov:skip=CKV_AWS_107:A boundary is a ceiling, not a grant. Nodes need ecr:GetAuthorizationToken to pull images; each role's own policy decides what it actually gets.
  # checkov:skip=CKV_AWS_108:A boundary is a ceiling, not a grant. The app must read its own DB secret; its role policy limits that to one secret ARN.
  statement {
    sid = "WorkloadServices"
    actions = [
      "autoscaling:*",
      "cloudwatch:*",
      "ec2:*",
      "ec2messages:*",
      "ecr:*",
      "eks:*",
      "eks-auth:*",
      "elasticloadbalancing:*",
      "logs:*",
      "shield:*",
      "ssm:*",
      "ssmmessages:*",
      "tag:GetResources",
      "tag:TagResources",
      "tag:UntagResources",
      "waf-regional:*",
      "wafv2:*",
      "xray:*",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListCertificates",
      "cognito-idp:DescribeUserPoolClient",
      "iam:GetServerCertificate",
      "iam:ListServerCertificates",
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ListGrants",
      "kms:ReEncrypt*",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "LoadBalancerServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  # ExternalDNS keeps the app's record pointed at the current ALB. It may only
  # change records in the app zone; listing zones cannot be scoped.
  dynamic "statement" {
    for_each = var.dns_zone_name == null ? [] : [1]
    content {
      sid       = "AppZoneRecords"
      actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
      resources = [local.zone_arn]
    }
  }

  dynamic "statement" {
    for_each = var.dns_zone_name == null ? [] : [1]
    content {
      sid       = "ListZones"
      actions   = ["route53:ListHostedZones", "route53:ListTagsForResources"]
      resources = ["*"]
    }
  }

  # The Synthetics canary writes its run artifacts to its own bucket, and
  # lists buckets to find it. No other bucket, so never the state bucket.
  statement {
    sid     = "CanaryArtifacts"
    actions = ["s3:PutObject", "s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [
      "${local.arn_prefix}:s3:::${local.stack}-canary-*",
      "${local.arn_prefix}:s3:::${local.stack}-canary-*/*",
    ]
  }

  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # Managed Prometheus: the collector writes, Grafana reads.
  statement {
    sid = "ManagedPrometheus"
    actions = [
      "aps:RemoteWrite", "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels",
      "aps:GetMetricMetadata", "aps:DescribeWorkspace", "aps:ListWorkspaces",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "NeverTheStateKey"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.stack}-workload-boundary"
  description = "Permissions boundary for every IAM role created by the ${local.stack} main stack"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# --- Trust policies ---------------------------------------------------------------

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    # Pull requests, plus main: the apply workflow shows a read-only plan for
    # review before the approval-gated apply job starts.
    plan = [
      "${local.github_sub_prefix}:pull_request",
      "${local.github_sub_prefix}:ref:refs/heads/main",
    ]
    apply = ["${local.github_sub_prefix}:${var.github_apply_subject}"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match on repository and trigger. No wildcards: a wildcard here is
    # how other repositories (or forks) end up able to assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = each.value
    }
  }

  # Lets an operator assume the role locally to test its permissions. Empty
  # by default; set ci_role_test_principals only while testing.
  dynamic "statement" {
    for_each = length(var.ci_role_test_principals) > 0 ? [1] : []

    content {
      sid     = "LocalPermissionTesting"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = var.ci_role_test_principals
      }
    }
  }
}

# --- Plan role: read-only --------------------------------------------------------

data "aws_iam_policy_document" "github_plan_state" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}"]
  }

  statement {
    sid       = "HoldTheLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}.tflock"]
  }

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "UseStateKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${local.stack}-github-plan"
  description          = "GitHub Actions: terraform plan on pull requests (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_plan_read" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "${local.arn_prefix}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "github_plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan_state.json
}

# --- Apply role: scoped writes ----------------------------------------------------
# Split across three policies to stay under IAM's 6,144-character limit.

data "aws_iam_policy_document" "github_apply_core" {
  statement {
    sid       = "StateObject"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}"]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key}.tflock"]
  }

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }

  # EC2 has little resource-level scoping for networking; limit by action
  # family and region instead. EKS launches the nodes; the only instance CI
  # launches is the jump host (LaunchJumpHost).
  statement {
    sid = "Networking"
    actions = [
      "ec2:Describe*",
      "ec2:Get*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:*Vpc",
      "ec2:*VpcAttribute",
      "ec2:*Subnet",
      "ec2:ModifySubnetAttribute",
      "ec2:*RouteTable",
      "ec2:*Route",
      "ec2:*InternetGateway",
      "ec2:*NatGateway",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:DisassociateAddress",
      "ec2:*SecurityGroup",
      "ec2:*SecurityGroupIngress",
      "ec2:*SecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptions*",
      "ec2:*NetworkAcl",
      "ec2:*NetworkAclEntry",
      "ec2:ReplaceNetworkAclAssociation",
      "ec2:*FlowLogs",
      "ec2:*LaunchTemplate",
      # Singular and plural are different actions: CreateLaunchTemplateVersion
      # (node group updates) vs Delete/DescribeLaunchTemplateVersions.
      "ec2:CreateLaunchTemplateVersion",
      "ec2:*LaunchTemplateVersions",
      "ec2:DeleteNetworkInterface",
      "ec2:EnableEbsEncryptionByDefault",
      "ec2:DisableEbsEncryptionByDefault",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # The SSM jump host for the private EKS API: one small instance, tagged as
  # this stack. The other RunInstances resources (subnet, security group,
  # image, ...) are only referenced, so they cannot be narrowed further.
  statement {
    sid       = "LaunchJumpHost"
    actions   = ["ec2:RunInstances"]
    resources = ["${local.arn_prefix}:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = ["t3.micro"]
    }
  }

  # Updating a node group to a new launch template makes EKS dry-run
  # RunInstances as the caller. Allowed only for the node instance types, and
  # only through a launch template that carries this stack's tag.
  statement {
    sid       = "LaunchNodesFromStackTemplates"
    actions   = ["ec2:RunInstances"]
    resources = ["${local.arn_prefix}:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = var.node_instance_types
    }

    condition {
      test     = "ArnLike"
      variable = "ec2:LaunchTemplate"
      values   = ["${local.arn_prefix}:ec2:${var.region}:${local.account_id}:launch-template/*"]
    }
  }

  statement {
    sid       = "StackLaunchTemplates"
    actions   = ["ec2:RunInstances"]
    resources = ["${local.arn_prefix}:ec2:${var.region}:${local.account_id}:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  statement {
    sid     = "LaunchJumpHostResources"
    actions = ["ec2:RunInstances"]
    resources = [
      "${local.arn_prefix}:ec2:${var.region}:${local.account_id}:subnet/*",
      "${local.arn_prefix}:ec2:${var.region}:${local.account_id}:security-group/*",
      "${local.arn_prefix}:ec2:${var.region}:${local.account_id}:network-interface/*",
      "${local.arn_prefix}:ec2:${var.region}:${local.account_id}:volume/*",
      "${local.arn_prefix}:ec2:${var.region}::image/*",
    ]
  }

  statement {
    sid = "ManageStackInstances"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:AssociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation",
      "ec2:DisassociateIamInstanceProfile",
      "ec2:MonitorInstances",
      "ec2:UnmonitorInstances",
    ]
    resources = ["${local.arn_prefix}:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  # The jump host's AMI comes from AWS's public parameter.
  statement {
    sid       = "PublicAmiParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.arn_prefix}:ssm:${var.region}::parameter/aws/service/*"]
  }

  statement {
    sid     = "Cluster"
    actions = ["eks:*"]
    resources = [
      "${local.arn_prefix}:eks:${var.region}:${local.account_id}:cluster/${local.stack}",
      "${local.arn_prefix}:eks:${var.region}:${local.account_id}:nodegroup/${local.stack}/*",
      "${local.arn_prefix}:eks:${var.region}:${local.account_id}:addon/${local.stack}/*",
      "${local.arn_prefix}:eks:${var.region}:${local.account_id}:access-entry/${local.stack}/*",
    ]
  }

  statement {
    sid       = "ClusterRead"
    actions   = ["eks:Describe*", "eks:List*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "github_apply_iam" {
  # Roles can only be created, or given permissions, if they carry the boundary.
  statement {
    sid = "RolesMustCarryBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/${local.stack}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid = "ManageStackRoles"
    actions = [
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/${local.stack}-*"]
  }

  statement {
    sid = "ManageStackPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:policy/${local.stack}-*"]
  }

  statement {
    sid = "ManageStackInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:instance-profile/${local.stack}-*"]
  }

  statement {
    sid       = "PassStackRoles"
    actions   = ["iam:PassRole"]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/${local.stack}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com",
        "ec2.amazonaws.com",
        "monitoring.rds.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
        "lambda.amazonaws.com",
        # CreateCanary passes the canary role as Synthetics itself.
        "synthetics.amazonaws.com",
        "grafana.amazonaws.com",
      ]
    }
  }

  statement {
    sid = "ClusterOidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "rds.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Explicit denies win over every allow above.
  statement {
    sid    = "NeverTheCiOrBoundary"
    effect = "Deny"
    actions = [
      "iam:Add*", "iam:Attach*", "iam:Create*", "iam:Delete*", "iam:Detach*",
      "iam:PassRole", "iam:Put*", "iam:Remove*", "iam:Set*", "iam:Tag*",
      "iam:Untag*", "iam:Update*",
    ]
    resources = [
      "${local.arn_prefix}:iam::${local.account_id}:role/${local.stack}-github-*",
      "${local.arn_prefix}:iam::${local.account_id}:policy/${local.stack}-workload-boundary",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  statement {
    sid       = "NeverRemoveABoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "github_apply_services" {
  statement {
    sid       = "CreateTaggedKeys"
    actions   = ["kms:CreateKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  # Not tag-scoped: a new tag can take up to 5 minutes to count for KMS
  # authorization, and Terraform reads and configures a key straight after
  # CreateKey. Region-wide instead, with the state key denied explicitly.
  statement {
    sid = "ManageKeys"
    actions = [
      # Alias calls are authorized against the key as well as the alias.
      "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
      "kms:CancelKeyDeletion", "kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey",
      "kms:DisableKey", "kms:DisableKeyRotation", "kms:EnableKey", "kms:EnableKeyRotation",
      "kms:Encrypt", "kms:GenerateDataKey*", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
      "kms:ListGrants", "kms:ListResourceTags", "kms:PutKeyPolicy", "kms:RetireGrant",
      "kms:RevokeGrant", "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource",
      "kms:UpdateKeyDescription",
    ]
    resources = ["${local.arn_prefix}:kms:${var.region}:${local.account_id}:key/*"]
  }

  # Only the four actions Terraform needs to read and write state.
  statement {
    sid         = "StateKeyOnlyForState"
    effect      = "Deny"
    not_actions = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey"]
    resources   = [aws_kms_key.state.arn]
  }

  statement {
    sid     = "StackKeyAliases"
    actions = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = [
      "${local.arn_prefix}:kms:${var.region}:${local.account_id}:alias/${local.stack}-*",
      "${local.arn_prefix}:kms:${var.region}:${local.account_id}:alias/eks/${local.stack}",
    ]
  }

  statement {
    sid     = "Database"
    actions = ["rds:*"]
    resources = [
      "${local.arn_prefix}:rds:${var.region}:${local.account_id}:db:${local.stack}",
      "${local.arn_prefix}:rds:${var.region}:${local.account_id}:subgrp:${local.stack}*",
      "${local.arn_prefix}:rds:${var.region}:${local.account_id}:pg:${local.stack}-*",
      "${local.arn_prefix}:rds:${var.region}:${local.account_id}:og:default:*",
    ]
  }

  # RDS creates and rotates its own master-password secret (rds!...) on the
  # caller's behalf, so the caller needs rights to manage those secrets, but
  # never to read their value: CI cannot see the database password.
  statement {
    sid = "DatabaseManagedSecret"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret", "secretsmanager:RotateSecret",
      "secretsmanager:TagResource", "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = ["${local.arn_prefix}:secretsmanager:${var.region}:${local.account_id}:secret:rds!*"]
  }

  statement {
    sid     = "StackLogGroups"
    actions = ["logs:*"]
    resources = [
      "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:/aws/eks/${local.stack}/*",
      "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:/aws/containerinsights/${local.stack}/*",
      "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:/aws/rds/instance/${local.stack}/*",
      "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:/aws/vpc-flow-log/*",
      "${local.arn_prefix}:logs:${var.region}:${local.account_id}:log-group:aws-waf-logs-${local.stack}-*",
    ]
  }

  # WAF log delivery and account-level log reads do not support resource scoping.
  statement {
    sid = "LogDelivery"
    actions = [
      "logs:CreateLogDelivery", "logs:DeleteLogDelivery", "logs:GetLogDelivery",
      "logs:ListLogDeliveries", "logs:UpdateLogDelivery", "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "AlarmsAndDashboard"
    actions = ["cloudwatch:*"]
    resources = [
      "${local.arn_prefix}:cloudwatch:${var.region}:${local.account_id}:alarm:${local.stack}-*",
      "${local.arn_prefix}:cloudwatch::${local.account_id}:dashboard/${local.stack}",
    ]
  }

  statement {
    sid       = "CloudWatchRead"
    actions   = ["cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "AlertTopic"
    actions   = ["sns:*"]
    resources = ["${local.arn_prefix}:sns:${var.region}:${local.account_id}:${local.stack}-*"]
  }

  statement {
    sid       = "ImageRepository"
    actions   = ["ecr:*"]
    resources = ["${local.arn_prefix}:ecr:${var.region}:${local.account_id}:repository/${local.stack}/*"]
  }

  statement {
    sid     = "WebAcl"
    actions = ["wafv2:*"]
    resources = [
      "${local.arn_prefix}:wafv2:${var.region}:${local.account_id}:regional/webacl/${local.stack}-*/*",
      "${local.arn_prefix}:wafv2:${var.region}:${local.account_id}:regional/managedruleset/*/*",
    ]
  }

  statement {
    sid = "AccountReads"
    actions = [
      "wafv2:Describe*", "wafv2:Get*", "wafv2:List*", "wafv2:CheckCapacity",
      "acm:Describe*", "acm:List*", "ecr:GetAuthorizationToken", "ecr:DescribeRepositories",
      "rds:Describe*", "rds:ListTagsForResource", "kms:List*", "sns:List*",
      "route53:ListHostedZones*", "route53:GetChange", "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RequestTaggedCertificate"
    actions   = ["acm:RequestCertificate", "acm:AddTagsToCertificate"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  statement {
    sid = "ManageStackCertificates"
    actions = [
      "acm:AddTagsToCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate",
      "acm:GetCertificate", "acm:ListTagsForCertificate", "acm:RemoveTagsFromCertificate",
      "acm:RenewCertificate", "acm:UpdateCertificateOptions",
    ]
    resources = ["${local.arn_prefix}:acm:${var.region}:${local.account_id}:certificate/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  # Records in the app's zone only; the zone itself belongs to this bootstrap.
  statement {
    sid = "AppDnsRecords"
    actions = [
      "route53:ChangeResourceRecordSets", "route53:GetHostedZone",
      "route53:ListResourceRecordSets", "route53:ListTagsForResource",
    ]
    resources = [local.zone_arn]
  }
}

# Observability outside the cluster: the external Synthetics canary (which
# Synthetics deploys as a Lambda function under the caller's permissions)
# and Managed Prometheus. Scoped to this stack's names and tags.
data "aws_iam_policy_document" "github_apply_observability" {
  # Create actions are authorized against "*" (the resource does not exist
  # yet), so they are scoped by the stack tag Terraform adds to everything.
  statement {
    sid       = "CreateTaggedCanaries"
    actions   = ["synthetics:CreateCanary", "synthetics:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  statement {
    sid       = "StackCanaries"
    actions   = ["synthetics:*"]
    resources = ["${local.arn_prefix}:synthetics:${var.region}:${local.account_id}:canary:${local.stack}-*"]
  }

  statement {
    sid       = "ReadCanaries"
    actions   = ["synthetics:Describe*", "synthetics:Get*", "synthetics:List*"]
    resources = ["*"]
  }

  # Synthetics names the function and layer cwsyn-<canary>-<id>.
  statement {
    sid = "CanaryFunction"
    actions = [
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction",
      "lambda:GetFunctionConfiguration", "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration", "lambda:PublishVersion",
      "lambda:ListVersionsByFunction", "lambda:AddPermission", "lambda:RemovePermission",
      "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
      "lambda:PublishLayerVersion", "lambda:DeleteLayerVersion", "lambda:GetLayerVersion",
    ]
    resources = [
      "${local.arn_prefix}:lambda:${var.region}:${local.account_id}:function:cwsyn-${local.stack}-*",
      "${local.arn_prefix}:lambda:${var.region}:${local.account_id}:layer:cwsyn-${local.stack}-*",
      "${local.arn_prefix}:lambda:${var.region}:${local.account_id}:layer:cwsyn-${local.stack}-*:*",
    ]
  }

  # The Synthetics runtime layers are published by AWS accounts.
  statement {
    sid       = "SyntheticsRuntimeLayers"
    actions   = ["lambda:GetLayerVersion"]
    resources = ["${local.arn_prefix}:lambda:${var.region}:*:layer:*"]
  }

  # The canary's artifact bucket only (never the state bucket).
  statement {
    sid     = "CanaryBucket"
    actions = ["s3:*"]
    resources = [
      "${local.arn_prefix}:s3:::${local.stack}-canary-*",
      "${local.arn_prefix}:s3:::${local.stack}-canary-*/*",
    ]
  }

  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  statement {
    sid       = "CreateTaggedPrometheus"
    actions   = ["aps:CreateWorkspace", "aps:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  statement {
    sid = "ManageStackPrometheus"
    actions = [
      "aps:DeleteWorkspace", "aps:UpdateWorkspaceAlias", "aps:UntagResource",
      "aps:CreateLoggingConfiguration", "aps:UpdateLoggingConfiguration",
      "aps:DeleteLoggingConfiguration",
    ]
    resources = ["${local.arn_prefix}:aps:${var.region}:${local.account_id}:workspace/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.stack_tag.key}"
      values   = [local.stack_tag.value]
    }
  }

  statement {
    sid = "ReadPrometheus"
    actions = [
      "aps:DescribeWorkspace", "aps:ListWorkspaces", "aps:ListTagsForResource",
      "aps:DescribeLoggingConfiguration",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_apply" {
  for_each = {
    core          = data.aws_iam_policy_document.github_apply_core.json
    iam           = data.aws_iam_policy_document.github_apply_iam.json
    services      = data.aws_iam_policy_document.github_apply_services.json
    observability = data.aws_iam_policy_document.github_apply_observability.json
  }

  name        = "${local.stack}-github-apply-${each.key}"
  description = "GitHub Actions apply role: ${each.key} permissions for the ${local.stack} main stack"
  policy      = each.value
}

resource "aws_iam_role" "github_apply" {
  name                 = "${local.stack}-github-apply"
  description          = "GitHub Actions: terraform apply for the main stack (scoped)"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["apply"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_apply" {
  for_each = aws_iam_policy.github_apply

  role       = aws_iam_role.github_apply.name
  policy_arn = each.value.arn
}
