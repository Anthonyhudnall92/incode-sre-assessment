locals {
  metrics_ns    = "${var.name}/App"
  alarm_actions = [aws_sns_topic.alerts.arn]

}

# --- Alert routing -----------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Log-derived application metrics -----------------------------------------------
# The app writes one JSON line per request. Fluent Bit merges it into
# `log_processed`, so these filters turn logs into request/error counters
# without the app needing CloudWatch permissions.

resource "aws_cloudwatch_log_metric_filter" "app_requests" {
  name           = "${var.app_name}-requests"
  log_group_name = var.application_log_group_name
  pattern        = "{ ($.kubernetes.namespace_name = \"${var.app_namespace}\") && ($.log_processed.event = \"http_request\") }"

  metric_transformation {
    name          = "RequestCount"
    namespace     = local.metrics_ns
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_5xx" {
  name           = "${var.app_name}-5xx"
  log_group_name = var.application_log_group_name
  pattern        = "{ ($.kubernetes.namespace_name = \"${var.app_namespace}\") && ($.log_processed.status >= 500) }"

  metric_transformation {
    name          = "Http5xxCount"
    namespace     = local.metrics_ns
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_db_errors" {
  name           = "${var.app_name}-db-errors"
  log_group_name = var.application_log_group_name
  pattern        = "{ ($.kubernetes.namespace_name = \"${var.app_namespace}\") && ($.log_processed.event = \"db_error\") }"

  metric_transformation {
    name          = "DbErrorCount"
    namespace     = local.metrics_ns
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# Failed checks of the monitors that page on-call (alert=true: our own
# services). Failures of sites visitors add are shown on the board only.
resource "aws_cloudwatch_log_metric_filter" "monitor_down" {
  name           = "${var.app_name}-monitor-down"
  log_group_name = var.application_log_group_name
  pattern        = "{ ($.kubernetes.namespace_name = \"${var.app_namespace}\") && ($.log_processed.event = \"check_failed\") && ($.log_processed.alert IS TRUE) }"

  metric_transformation {
    name          = "MonitorDownCount"
    namespace     = local.metrics_ns
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# One heartbeat a minute from each app pod (the checker loop). If these stop,
# either the app or the log pipeline is down, and every log-based alarm
# above would be reading silence as "no errors".
resource "aws_cloudwatch_log_metric_filter" "heartbeat" {
  name           = "${var.app_name}-heartbeat"
  log_group_name = var.application_log_group_name
  pattern        = "{ ($.kubernetes.namespace_name = \"${var.app_namespace}\") && ($.log_processed.event = \"heartbeat\") }"

  metric_transformation {
    name      = "HeartbeatCount"
    namespace = local.metrics_ns
    value     = "1"
    unit      = "Count"
    # No default_value: when nothing arrives, the metric is missing, and
    # the alarm below treats missing as breaching.
  }
}

# --- Alarms --------------------------------------------------------------------------

# Symptom-based (what users feel) first ...

resource "aws_cloudwatch_metric_alarm" "app_5xx" {
  alarm_name          = "${var.name}-${var.app_name}-5xx"
  alarm_description   = "App is returning 5xx responses. Check pod logs and DB connectivity."
  namespace           = local.metrics_ns
  metric_name         = "Http5xxCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Synthetic check: a service we own failed its uptime check in 2 of the last
# 3 minutes (checks run every minute). One blip does not page; recovery
# sends an OK notification.
resource "aws_cloudwatch_metric_alarm" "monitor_down" {
  alarm_name          = "${var.name}-${var.app_name}-monitor-down"
  alarm_description   = "A service we own is failing its uptime check (see the board). Drill: make incident MODE=ok."
  namespace           = local.metrics_ns
  metric_name         = "MonitorDownCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Dead man's switch for the telemetry itself.
resource "aws_cloudwatch_metric_alarm" "telemetry_silent" {
  alarm_name          = "${var.name}-${var.app_name}-telemetry-silent"
  alarm_description   = "No app heartbeat reached CloudWatch for 5 minutes: the app or the log pipeline (Fluent Bit) is down, so the log-based alarms cannot see errors."
  namespace           = local.metrics_ns
  metric_name         = "HeartbeatCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "app_no_running_pods" {
  alarm_name          = "${var.name}-${var.app_name}-no-running-pods"
  alarm_description   = "No running pods behind the ${var.app_name} Service: the app is down."
  namespace           = "ContainerInsights"
  metric_name         = "service_number_of_running_pods"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = var.app_namespace
    Service     = var.app_name
  }
}

# ... then cause-based signals that explain them.

resource "aws_cloudwatch_metric_alarm" "app_restarts" {
  alarm_name          = "${var.name}-${var.app_name}-container-restarts"
  alarm_description   = "Containers are restarting (crash loop, OOMKill or failing liveness probe)."
  namespace           = "ContainerInsights"
  metric_name         = "pod_number_of_container_restarts"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = var.app_namespace
    PodName     = var.app_name
  }
}

resource "aws_cloudwatch_metric_alarm" "app_db_errors" {
  alarm_name          = "${var.name}-${var.app_name}-db-errors"
  alarm_description   = "App cannot talk to RDS (network, TLS, credentials or rotation)."
  namespace           = local.metrics_ns
  metric_name         = "DbErrorCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  alarm_name          = "${var.name}-node-cpu-high"
  alarm_description   = "Cluster node CPU sustained above 80%. Consider scaling the node group."
  namespace           = "ContainerInsights"
  metric_name         = "node_cpu_utilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    ClusterName = var.cluster_name
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "RDS CPU sustained above 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB (autoscaling max may be reached)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name}-rds-connections-high"
  alarm_description   = "RDS connections approaching the db.t3.micro limit (~80)."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "${var.name}-rds-freeable-memory-low"
  alarm_description   = "RDS freeable memory below 100 MiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 104857600
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

# --- Dashboard -----------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "alarm"
          x      = 0
          y      = 0
          width  = 24
          height = 3
          properties = {
            title = "Alarm status"
            alarms = [
              aws_cloudwatch_metric_alarm.monitor_down.arn,
              aws_cloudwatch_metric_alarm.telemetry_silent.arn,
              aws_cloudwatch_metric_alarm.app_5xx.arn,
              aws_cloudwatch_metric_alarm.app_no_running_pods.arn,
              aws_cloudwatch_metric_alarm.app_restarts.arn,
              aws_cloudwatch_metric_alarm.app_db_errors.arn,
              aws_cloudwatch_metric_alarm.node_cpu.arn,
              aws_cloudwatch_metric_alarm.rds_cpu.arn,
              aws_cloudwatch_metric_alarm.rds_storage.arn,
              aws_cloudwatch_metric_alarm.rds_connections.arn,
              aws_cloudwatch_metric_alarm.rds_memory.arn,
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 3
          width  = 12
          height = 6
          properties = {
            title  = "App requests vs 5xx (from logs)"
            region = var.region
            stat   = "Sum"
            period = 60
            metrics = [
              [local.metrics_ns, "RequestCount"],
              [local.metrics_ns, "Http5xxCount"],
              [local.metrics_ns, "DbErrorCount"],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 3
          width  = 12
          height = 6
          properties = {
            title  = "App pods: running / restarts"
            region = var.region
            period = 60
            metrics = [
              ["ContainerInsights", "service_number_of_running_pods", "ClusterName", var.cluster_name, "Namespace", var.app_namespace, "Service", var.app_name, { stat = "Minimum" }],
              ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.cluster_name, "Namespace", var.app_namespace, "PodName", var.app_name, { stat = "Maximum" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 9
          width  = 12
          height = 6
          properties = {
            title  = "App pod CPU / memory utilization (% of limit)"
            region = var.region
            stat   = "Average"
            period = 60
            metrics = [
              ["ContainerInsights", "pod_cpu_utilization_over_pod_limit", "ClusterName", var.cluster_name, "Namespace", var.app_namespace, "PodName", var.app_name],
              ["ContainerInsights", "pod_memory_utilization_over_pod_limit", "ClusterName", var.cluster_name, "Namespace", var.app_namespace, "PodName", var.app_name],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 9
          width  = 12
          height = 6
          properties = {
            title  = "Nodes: CPU / memory utilization"
            region = var.region
            stat   = "Average"
            period = 60
            metrics = [
              ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name],
              ["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 12
          height = 6
          properties = {
            title  = "RDS: CPU % and connections"
            region = var.region
            period = 60
            metrics = [
              ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Average" }],
              ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Maximum", yAxis = "right" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 15
          width  = 12
          height = 6
          properties = {
            title  = "RDS: read / write latency (s)"
            region = var.region
            stat   = "Average"
            period = 60
            metrics = [
              ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.db_instance_identifier],
              ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.db_instance_identifier],
            ]
          }
        },
      ],
      var.waf_web_acl_name == "" ? [] : [
        {
          type   = "metric"
          x      = 0
          y      = 21
          width  = 24
          height = 6
          properties = {
            title  = "WAF: allowed vs blocked"
            region = var.region
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/WAFV2", "AllowedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "ALL"],
              ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "ALL"],
            ]
          }
        },
      ],
    )
  })
}
