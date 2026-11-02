# Runbook

All alarms publish to the `<name>-alerts` SNS topic. Start from the CloudWatch dashboard
(`terraform -chdir=terraform output dashboard_url`).

Useful commands:

The EKS API is private. Open the tunnel first and leave it running:

```bash
make tunnel                             # SSM port forward: 127.0.0.1:8443 -> private API
```

Then, in another terminal:

```bash
make kubeconfig                         # writes .kube/config; never use another context
export KUBECONFIG=$PWD/.kube/config
kubectl -n uptime get pods -o wide
kubectl -n uptime describe pod <pod>
kubectl -n uptime logs deploy/uptime --since=15m
kubectl -n uptime get events --sort-by=.lastTimestamp
```

### Reaching the cluster

- **`make tunnel` fails with `TargetNotConnected`:** the jump host's SSM agent is not online.
  `aws ssm describe-instance-information` should list it as `Online`; if the instance is gone or
  broken, replace it: `terraform -chdir=terraform apply -replace=module.jump_host.aws_instance.this`
  through a PR, or locally in an emergency.
- **Break-glass (SSM itself is down):** set `eks_public_access = true` (in `terraform.tfvars` and
  the `TF_VARS` secret), apply, then use `DIRECT=1 make kubeconfig` and `DIRECT=1 make addons`.
  The public endpoint accepts `admin_cidrs` only. Turn it off again the same way.

### Argo CD

Argo CD deploys the app and the cluster add-ons from `main`. Changes made with `kubectl` are
reverted within minutes (self-heal), so fix things in git.

```bash
kubectl -n argocd get applications      # SYNC STATUS should be Synced, HEALTH Healthy
make argocd                             # UI on https://localhost:8080, user admin
make argocd-password                    # the admin password, from Secrets Manager
```

- **OutOfSync that will not clear:** open the app in the UI and look at the diff. A sync error
  (for example a value the chart rejects) is shown under the app's conditions.
- **Roll back a release:** revert the PR that changed the image digest. Argo CD rolls back to the
  previous digest. Do not use the UI's rollback; self-heal would undo it.
- **Rotate the admin password:** `terraform -chdir=addons apply -replace=random_password.argocd_admin`
  (through `make tunnel`). The new one goes to Secrets Manager and Argo CD gets only its hash.
- **Emergency pause:** `kubectl -n argocd patch application uptime --type merge -p
  '{"spec":{"syncPolicy":{"automated":null}}}'` stops automatic syncs until `make addons` restores
  them.

CloudWatch Logs Insights (log group `/aws/containerinsights/<cluster>/application`):

```
fields @timestamp, log_processed.status, log_processed.path, log_processed.error
| filter kubernetes.namespace_name = "uptime"
| filter log_processed.status >= 500 or log_processed.event = "db_error"
| sort @timestamp desc
| limit 50
```

---

### `*-monitor-down` — a service we own is failing its uptime check (user-facing)

The board checks our own services (the board's `/healthz` and the demo service) every minute
from inside the cluster, through the public URL. This alarm fires when one of them fails in 2 of
the last 3 minutes, and sends an OK notification when it recovers.

1. Open the board: the failing row is red, and its last result says why (HTTP status, timeout,
   TLS, DNS).
2. If it is **Demo service**, check whether a drill is running: `make incident MODE=ok` ends it.
3. If it is **This board** but the board loads for you, the path from the cluster out to the
   ALB is broken (NAT, DNS, WAF); compare with the `*-5xx` alarm.

### `*-telemetry-silent` — no app heartbeat for 5 minutes

Each app pod logs a `heartbeat` line every minute. When none reach CloudWatch, either the app
is down or the log path is broken, and the log-based alarms (`*-5xx`, `*-db-errors`,
`*-monitor-down`) cannot see anything: treat their silence as unknown, not healthy.

1. `kubectl -n uptime get pods`: if the app is down, see **no-running-pods**.
2. If the app is up, check Fluent Bit: `kubectl -n amazon-cloudwatch get pods` and its logs.
3. Check the board directly in a browser; the external Synthetics canary (when added) covers
   the public path independently.

### Incident drill (for demos)

With `make tunnel` running:

```bash
make incident MODE=down   # demo service returns 503: the board goes red within a minute,
                          # the error budget is spent, and *-monitor-down emails in ~2-3 min
make incident MODE=slow   # 4-second responses: tall bars and a p95 jump, but still up
make incident MODE=ok     # recover: green again, then an OK email
```

The switch only accepts connections from inside the pod, so it is reached with `kubectl exec`
(your IAM identity and RBAC), never through the ALB. The drill's 503s are logged as
`demo_request`, not `http_request`, so they do not trip the app's own `*-5xx` alarm.

### `*-5xx` — app returning server errors (user-facing)

1. Check `DbErrorCount` on the dashboard. If it is rising too, go to **db-errors**.
2. Otherwise check recent releases: `git log -p -- deploy/charts/uptime/values.yaml`.
   Roll back by reverting that PR (see **Argo CD**); `kubectl rollout undo` would be reverted.

### `*-no-running-pods` — app is down (user-facing)

1. `kubectl -n uptime get pods`. `Pending`: check node capacity and events.
   `CrashLoopBackOff`: check logs. `ImagePullBackOff`: check the digest exists in ECR.
2. PSA rejections show as `FailedCreate` events on the ReplicaSet.

### `*-container-restarts`

1. `kubectl -n uptime describe pod` → `Last State`. `OOMKilled`: raise the memory limit.
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
