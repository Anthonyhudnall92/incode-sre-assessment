# Runbook

All alarms publish to the `<name>-alerts` SNS topic. Start from the CloudWatch dashboard
(`terraform -chdir=terraform output dashboard_url`).

Useful commands:

```bash
kubectl -n demo get pods -o wide
kubectl -n demo describe pod <pod>
kubectl -n demo logs deploy/demo-app --since=15m
kubectl -n demo get events --sort-by=.lastTimestamp
```

CloudWatch Logs Insights (log group `/aws/containerinsights/<cluster>/application`):

```
fields @timestamp, log_processed.status, log_processed.path, log_processed.error
| filter kubernetes.namespace_name = "demo"
| filter log_processed.status >= 500 or log_processed.event = "db_error"
| sort @timestamp desc
| limit 50
```

---

### `*-5xx` — app returning server errors (user-facing)

1. Check `DbErrorCount` on the dashboard. If it is rising too, go to **db-errors**.
2. Otherwise check recent deploys: `kubectl -n demo rollout history deploy/demo-app`.
   Roll back with `kubectl -n demo rollout undo deploy/demo-app`.

### `*-no-running-pods` — app is down (user-facing)

1. `kubectl -n demo get pods`. `Pending`: check node capacity and events.
   `CrashLoopBackOff`: check logs. `ImagePullBackOff`: check the digest exists in ECR.
2. PSA rejections show as `FailedCreate` events on the ReplicaSet.

### `*-container-restarts`

1. `kubectl -n demo describe pod` → `Last State`. `OOMKilled`: raise the memory limit.
2. Liveness failures: `/healthz` has no dependencies, so look for a hung process.

### `*-db-errors` — app cannot reach PostgreSQL

1. Log field `error_type`:
   - `OperationalError` + timeout: network. Check NetworkPolicy egress and the RDS SG.
   - `password authentication failed`: the app refreshes the secret once automatically. If it
     persists, check the secret and the app role (`aws secretsmanager describe-secret`).
   - SSL errors: CA bundle or `rds.force_ssl`.
2. RDS events: `aws rds describe-events --source-identifier <name> --duration 60`.

### `*-node-cpu-high`

Check which pods use CPU (`kubectl top pods -A` if metrics-server is installed, or Container
Insights). Scale the node group (`node_desired_size`) or tune requests/limits.

### `*-rds-cpu-high` / `*-rds-connections-high` / `*-rds-freeable-memory-low`

Check slow queries in the `postgresql` log group (`log_min_duration_statement = 500ms`) and
connection counts per client. Scale `db_instance_class` if load is genuine.

### `*-rds-free-storage-low`

Storage autoscaling goes up to 50 GiB (`max_allocated_storage`). Find what grew; raise the cap if
growth is expected.
