# -----------------------------------------------------------------------------
# Amazon Managed Service for Prometheus, and the collector's identity
#
# Metrics are stored outside the cluster, so they survive it. The in-cluster
# collector (ADOT, deployed by Argo CD from addons/) scrapes the app and
# writes here with SigV4; its role can write to this one workspace and send
# X-Ray traces, nothing else.
# -----------------------------------------------------------------------------

resource "aws_prometheus_workspace" "this" {
  # checkov:skip=CKV_AWS_351:Encrypted at rest with an AWS-owned key; the metrics are request counts and latencies, no customer data
  alias = var.name
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid       = "WriteMetrics"
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.this.arn]
  }

  statement {
    sid = "SendTraces"
    actions = [
      "xray:PutTraceSegments", "xray:PutTelemetryRecords",
      "xray:GetSamplingRules", "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "collector" {
  name        = "${var.name}-adot-collector"
  description = "ADOT collector: write metrics to the stack's Managed Prometheus workspace, send traces to X-Ray"
  policy      = data.aws_iam_policy_document.collector.json
}

module "collector_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn

  role_name        = "${var.name}-adot-collector"
  role_policy_arns = { collector = aws_iam_policy.collector.arn }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.collector_namespace}:${var.collector_service_account}"]
    }
  }
}

# --- Grafana (in-cluster, addons/): read-only on the metrics, logs and traces --

data "aws_iam_policy_document" "grafana" {
  statement {
    sid = "QueryMetrics"
    actions = [
      "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata",
    ]
    resources = [aws_prometheus_workspace.this.arn]
  }

  # Grafana's CloudWatch data source: metrics, alarms and Logs Insights.
  statement {
    sid = "ReadCloudWatch"
    actions = [
      "cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData", "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery",
      "logs:StopQuery", "logs:GetQueryResults", "logs:GetLogEvents",
      "ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ReadTraces"
    actions = [
      "xray:BatchGetTraces", "xray:GetTraceSummaries", "xray:GetTraceGraph",
      "xray:GetServiceGraph", "xray:GetGroups", "xray:GetTimeSeriesServiceStatistics",
      "xray:GetInsightSummaries", "xray:GetInsight",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana" {
  name        = "${var.name}-grafana-read"
  description = "In-cluster Grafana: read Managed Prometheus, CloudWatch metrics, alarms and logs, and X-Ray traces"
  policy      = data.aws_iam_policy_document.grafana.json
}

module "grafana_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_permissions_boundary_arn = var.permissions_boundary_arn

  role_name        = "${var.name}-grafana"
  role_policy_arns = { read = aws_iam_policy.grafana.arn }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.collector_namespace}:grafana"]
    }
  }
}
