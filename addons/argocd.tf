# Argo CD, reachable only through `kubectl port-forward` (docs/runbook.md).
# No Ingress, no SSO, no notifications, no ApplicationSets.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    global = {
      # The chart's per-component policies, plus deny everything else in.
      networkPolicy = { create = true, defaultDenyIngress = true }
    }

    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }

    server = {
      service = { type = "ClusterIP" }
      ingress = { enabled = false }
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "768Mi" }
      }
    }

    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    redis = {
      resources = {
        requests = { cpu = "20m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  })]
}
