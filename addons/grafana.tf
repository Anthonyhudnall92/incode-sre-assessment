# In-cluster Grafana for exploring the data that lives outside the cluster:
# Managed Prometheus (app metrics, SigV4 through a read-only IRSA role) and
# CloudWatch (alarms, logs, the external canary). Paging stays in CloudWatch.
#
# Reached only through `make tunnel` + `make grafana` (no Ingress). The admin
# password is generated here, kept in Secrets Manager (`make grafana-password`)
# and handed to the pod as a Kubernetes Secret. Dashboards are JSON in git
# (addons/dashboards/), provisioned read-only.

locals {
  grafana_role_arn = try(local.main.grafana_role_arn, "")
  grafana          = local.grafana_role_arn != "" && local.collector

  grafana_app = local.grafana ? {
    grafana = {
      namespace  = "argocd"
      project    = "platform"
      finalizers = local.finalizers
      source = {
        repoURL        = "https://grafana-community.github.io/helm-charts"
        chart          = "grafana"
        targetRevision = var.grafana_chart_version
        helm = {
          releaseName = "grafana"
          valuesObject = {
            admin = {
              existingSecret = kubernetes_secret_v1.grafana_admin[0].metadata[0].name
              userKey        = "admin-user"
              passwordKey    = "admin-password" # gitleaks:allow (a key name, not a secret)
            }

            serviceAccount = {
              create      = true
              name        = "grafana"
              annotations = { "eks.amazonaws.com/role-arn" = local.grafana_role_arn }
            }
            # No cluster-wide RBAC (only the dashboard sidecar uses it), no
            # root chown init container (no persistent volume), no test pod.
            rbac           = { create = false }
            initChownData  = { enabled = false }
            testFramework  = { enabled = false }
            persistence    = { enabled = false }
            podAnnotations = { "checksum/dashboards" = sha256(file("${path.module}/dashboards/uptime.json")) }

            resources = {
              requests = { cpu = "50m", memory = "128Mi" }
              limits   = { memory = "384Mi" }
            }

            "grafana.ini" = {
              analytics = { check_for_updates = false, reporting_enabled = false }
              # The pod's IRSA role (web identity) is the "default" provider.
              aws              = { allowed_auth_providers = "default" }
              users            = { allow_sign_up = false }
              "auth.anonymous" = { enabled = false }
            }

            datasources = {
              "datasources.yaml" = {
                apiVersion = 1
                datasources = [
                  {
                    name      = "Managed Prometheus"
                    uid       = "prometheus"
                    type      = "prometheus"
                    access    = "proxy"
                    url       = trimsuffix(try(local.main.prometheus_query_url, ""), "/")
                    isDefault = true
                    jsonData = {
                      httpMethod    = "POST"
                      sigV4Auth     = true
                      sigV4AuthType = "default"
                      sigV4Region   = var.region
                      timeInterval  = "30s"
                    }
                  },
                  {
                    name   = "CloudWatch"
                    uid    = "cloudwatch"
                    type   = "cloudwatch"
                    access = "proxy"
                    jsonData = {
                      authType      = "default"
                      defaultRegion = var.region
                    }
                  },
                ]
              }
            }

            dashboardProviders = {
              "dashboardproviders.yaml" = {
                apiVersion = 1
                providers = [{
                  name            = "git"
                  folder          = "sre-demo"
                  type            = "file"
                  disableDeletion = true
                  editable        = false
                  options         = { path = "/var/lib/grafana/dashboards/git" }
                }]
              }
            }
            dashboards = {
              git = {
                uptime = { json = file("${path.module}/dashboards/uptime.json") }
              }
            }
          }
        }
      }
      destination = { server = local.in_cluster, namespace = local.collector_ns }
      syncPolicy  = local.sync
    }
  } : {}
}

# The namespace is Terraform's (with Pod Security "restricted"), so the admin
# Secret can exist before Argo CD deploys Grafana into it.
resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = local.collector_ns
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }

  lifecycle {
    # Argo CD may annotate it; Terraform owns the labels.
    ignore_changes = [metadata[0].annotations]
  }
}

import {
  to = kubernetes_namespace_v1.observability
  id = "observability"
}

resource "random_password" "grafana_admin" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  # checkov:skip=CKV2_AWS_57:Rotated by replacing random_password; Grafana local admin has no rotation Lambda
  name                    = "${var.cluster_name}/grafana-admin"
  description             = "Grafana admin login (username admin)"
  kms_key_id              = aws_kms_key.argocd_admin.arn # the admin-credentials key
  recovery_window_in_days = 0                            # exercise only
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana_admin.result
  })
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = local.grafana ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }

  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }
}
