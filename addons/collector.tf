# The ADOT collector (AWS Distro for OpenTelemetry): scrapes the app's
# /metrics and writes them to Managed Prometheus (SigV4, via its IRSA role),
# and receives OTLP traces for X-Ray. The metrics live outside the cluster.
#
# Only components ADOT ships are configured; the chart's defaults (jaeger,
# zipkin receivers, debug exporter) are switched off.

locals {
  collector_ns = "observability"
  # Empty until the main stack has created the workspace and role.
  prometheus_remote_write_url = try(local.main.prometheus_remote_write_url, "")
  adot_collector_role_arn     = try(local.main.adot_collector_role_arn, "")
  collector                   = local.prometheus_remote_write_url != "" && local.adot_collector_role_arn != ""

  collector_config = {
    extensions = {
      sigv4auth = { region = var.region, service = "aps" }
    }

    receivers = {
      jaeger = null
      zipkin = null
      prometheus = {
        config = {
          scrape_configs = [
            {
              job_name        = local.main.app_name
              scrape_interval = "30s"
              kubernetes_sd_configs = [{
                role       = "pod"
                namespaces = { names = [local.main.app_namespace] }
              }]
              relabel_configs = [
                # The app's pods only, on their http port.
                {
                  source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
                  regex         = local.main.app_name
                  action        = "keep"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_name"]
                  regex         = "http"
                  action        = "keep"
                },
                { source_labels = ["__meta_kubernetes_pod_name"], target_label = "pod" },
                { source_labels = ["__meta_kubernetes_namespace"], target_label = "namespace" },
                { source_labels = ["__meta_kubernetes_pod_node_name"], target_label = "node" },
              ]
            },
          ]
        }
      }
    }

    exporters = {
      debug = null
      prometheusremotewrite = {
        endpoint                         = local.main.prometheus_remote_write_url
        auth                             = { authenticator = "sigv4auth" }
        resource_to_telemetry_conversion = { enabled = true }
      }
      awsxray = { region = var.region }
    }

    service = {
      extensions = ["health_check", "sigv4auth"]
      pipelines = {
        logs = null
        metrics = {
          receivers  = ["prometheus"]
          processors = ["memory_limiter", "batch"]
          exporters  = ["prometheusremotewrite"]
        }
        traces = {
          receivers  = ["otlp"]
          processors = ["memory_limiter", "batch"]
          exporters  = ["awsxray"]
        }
      }
    }
  }

  collector_app = local.collector ? {
    adot-collector = {
      namespace  = "argocd"
      project    = "platform"
      finalizers = local.finalizers
      source = {
        repoURL        = "https://open-telemetry.github.io/opentelemetry-helm-charts"
        chart          = "opentelemetry-collector"
        targetRevision = var.otel_collector_chart_version
        helm = {
          releaseName = "adot-collector"
          valuesObject = {
            mode         = "deployment"
            replicaCount = 1
            image = {
              repository = "public.ecr.aws/aws-observability/aws-otel-collector"
              tag        = var.adot_collector_version
            }
            command = { name = "awscollector" }

            serviceAccount = {
              create      = true
              name        = "adot-collector"
              annotations = { "eks.amazonaws.com/role-arn" = local.adot_collector_role_arn }
            }
            # Pod discovery in the app namespace, read-only.
            clusterRole = {
              create = true
              rules = [{
                apiGroups = [""]
                resources = ["pods", "endpoints", "services"]
                verbs     = ["get", "list", "watch"]
              }]
            }

            podSecurityContext = {
              runAsNonRoot   = true
              runAsUser      = 10001
              runAsGroup     = 10001
              seccompProfile = { type = "RuntimeDefault" }
            }
            securityContext = {
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              capabilities             = { drop = ["ALL"] }
            }
            resources = {
              requests = { cpu = "50m", memory = "128Mi" }
              limits   = { memory = "256Mi" }
            }

            ports = {
              jaeger-compact = { enabled = false }
              jaeger-thrift  = { enabled = false }
              jaeger-grpc    = { enabled = false }
              zipkin         = { enabled = false }
            }

            config = local.collector_config
          }
        }
      }
      destination = { server = local.in_cluster, namespace = local.collector_ns }
      syncPolicy = merge(local.sync, {
        syncOptions = concat(local.sync.syncOptions, ["CreateNamespace=true"])
        # The collector's namespace enforces Pod Security "restricted" too.
        managedNamespaceMetadata = {
          labels = {
            "pod-security.kubernetes.io/enforce" = "restricted"
            "pod-security.kubernetes.io/warn"    = "restricted"
          }
        }
      })
    }
  } : {}
}
