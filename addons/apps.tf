# What Argo CD keeps in sync, and what each project is allowed to touch.
#
#   platform  kube-system and observability, from the upstream chart repos
#     aws-load-balancer-controller   ALBs for Ingresses
#     external-dns                   the app's DNS record (when a domain is set)
#     adot-collector                 app metrics to Managed Prometheus, traces to X-Ray
#   apps      the app's namespace only, from this repository
#     uptime                         deploy/charts/uptime on main
#
# Every app syncs automatically, reverts drift (selfHeal) and deletes what is
# no longer declared (prune). Deleting an Application deletes its resources
# (finalizer), which is how scripts/destroy.sh removes the ALB before the VPC.

data "aws_route53_zone" "app" {
  count   = local.dns ? 1 : 0
  zone_id = local.zone_id
}

data "aws_iam_role" "lb_controller" {
  name = "${local.main.cluster_name}-lb-controller"
}

locals {
  in_cluster = "https://kubernetes.default.svc"
  domain     = local.main.domain_name == null ? "" : local.main.domain_name
  zone_id    = local.main.route53_zone_id == null ? "" : local.main.route53_zone_id
  # Empty until the main stack has created the ExternalDNS role.
  external_dns_role_arn = try(local.main.external_dns_role_arn, "")
  dns                   = local.domain != "" && local.external_dns_role_arn != ""

  sync = {
    automated   = { prune = true, selfHeal = true }
    syncOptions = ["ServerSideApply=true"]
    retry = {
      limit   = 5
      backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
    }
  }
  finalizers = ["resources-finalizer.argocd.argoproj.io"]

  # The controller chart generates a new webhook certificate on every render
  # (Helm `lookup` does not run under Argo CD). Keep the one in the cluster
  # instead of rotating it on every sync.
  lb_controller_cert_ignores = [
    {
      group             = "admissionregistration.k8s.io"
      kind              = "MutatingWebhookConfiguration"
      jqPathExpressions = [".webhooks[]?.clientConfig.caBundle"]
    },
    {
      group             = "admissionregistration.k8s.io"
      kind              = "ValidatingWebhookConfiguration"
      jqPathExpressions = [".webhooks[]?.clientConfig.caBundle"]
    },
    {
      kind         = "Secret"
      name         = "aws-load-balancer-tls"
      jsonPointers = ["/data"]
    },
  ]

  projects = {
    platform = {
      namespace   = "argocd"
      description = "Cluster add-ons in kube-system"
      sourceRepos = [
        "https://aws.github.io/eks-charts",
        "https://kubernetes-sigs.github.io/external-dns/",
        "https://open-telemetry.github.io/opentelemetry-helm-charts",
      ]
      destinations = [
        { server = local.in_cluster, namespace = "kube-system" },
        { server = local.in_cluster, namespace = local.collector_ns },
      ]
      clusterResourceWhitelist = [
        { group = "", kind = "Namespace" },
        { group = "apiextensions.k8s.io", kind = "CustomResourceDefinition" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRole" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRoleBinding" },
        { group = "admissionregistration.k8s.io", kind = "MutatingWebhookConfiguration" },
        { group = "admissionregistration.k8s.io", kind = "ValidatingWebhookConfiguration" },
        { group = "networking.k8s.io", kind = "IngressClass" },
        { group = "elbv2.k8s.aws", kind = "IngressClassParams" },
      ]
    }

    apps = {
      namespace    = "argocd"
      description  = "Applications built from this repository"
      sourceRepos  = [var.repo_url]
      destinations = [{ server = local.in_cluster, namespace = local.main.app_namespace }]
      # Its own namespace (with Pod Security labels), nothing else cluster-wide.
      clusterResourceWhitelist = [{ group = "", kind = "Namespace" }]
    }
  }

  applications = merge(
    {
      aws-load-balancer-controller = {
        namespace  = "argocd"
        project    = "platform"
        finalizers = local.finalizers
        source = {
          repoURL        = "https://aws.github.io/eks-charts"
          chart          = "aws-load-balancer-controller"
          targetRevision = var.lb_controller_chart_version
          helm = {
            releaseName = "aws-load-balancer-controller"
            valuesObject = {
              clusterName = local.main.cluster_name
              # Passed explicitly because IMDS is not reachable from pods
              # (hop limit 1).
              region = var.region
              vpcId  = data.aws_eks_cluster.this.vpc_config[0].vpc_id
              serviceAccount = {
                name        = "aws-load-balancer-controller"
                annotations = { "eks.amazonaws.com/role-arn" = data.aws_iam_role.lb_controller.arn }
              }
            }
          }
        }
        destination       = { server = local.in_cluster, namespace = "kube-system" }
        syncPolicy        = merge(local.sync, { syncOptions = concat(local.sync.syncOptions, ["RespectIgnoreDifferences=true"]) })
        ignoreDifferences = local.lb_controller_cert_ignores
      }

      (local.main.app_name) = {
        namespace  = "argocd"
        project    = "apps"
        finalizers = local.finalizers
        source = {
          repoURL        = var.repo_url
          path           = "deploy/charts/uptime"
          targetRevision = var.repo_revision
          helm = {
            releaseName = local.main.app_name
            # Everything except the image digest, which is committed.
            valuesObject = {
              image   = { repository = local.main.ecr_repository_url }
              region  = var.region
              roleArn = local.main.app_role_arn
              vpcCidr = local.main.vpc_cidr
              db = {
                host        = local.main.db_host
                port        = local.main.db_port
                name        = local.main.db_name
                secretArn   = local.main.db_secret_arn
                subnetCidrs = local.main.database_subnet_cidrs
              }
              ingress = {
                host           = local.domain
                certificateArn = local.main.certificate_arn
                wafAclArn      = local.main.waf_web_acl_arn
              }
            }
          }
        }
        destination = { server = local.in_cluster, namespace = local.main.app_namespace }
        syncPolicy  = local.sync
      }
    },
    local.collector_app,
    local.dns ? {
      external-dns = {
        namespace  = "argocd"
        project    = "platform"
        finalizers = local.finalizers
        source = {
          repoURL        = "https://kubernetes-sigs.github.io/external-dns/"
          chart          = "external-dns"
          targetRevision = var.external_dns_chart_version
          helm = {
            releaseName = "external-dns"
            valuesObject = {
              provider = { name = "aws" }
              env      = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
              serviceAccount = {
                name        = "external-dns"
                annotations = { "eks.amazonaws.com/role-arn" = local.external_dns_role_arn }
              }
              sources = ["ingress"]
              # Only the app zone (the ID filter and its IAM role both hold it
              # there); never delete a record it did not create (TXT ownership
              # records mark its own). The domain filter must be the zone's
              # name: it selects zones, and the zone is not inside a filter
              # for one of its subdomains.
              domainFilters = [data.aws_route53_zone.app[0].name]
              extraArgs     = ["--zone-id-filter=${local.zone_id}"]
              policy        = "upsert-only"
              registry      = "txt"
              txtOwnerId    = local.main.cluster_name
              resources = {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "96Mi" }
              }
            }
          }
        }
        destination = { server = local.in_cluster, namespace = "kube-system" }
        syncPolicy  = local.sync
      }
    } : {}
  )
}

resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  chart     = "argocd-apps"
  version   = var.argocd_apps_chart_version
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"

  values = [yamlencode({
    projects     = local.projects
    applications = local.applications
  })]

  depends_on = [helm_release.argocd]
}
