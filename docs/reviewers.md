# Reviewer guide

For whoever evaluates this submission: what was asked, where each answer is, and how to check
it yourself. Reading order: this page, then the [README](../README.md) (architecture, security
baseline, exceptions, threat model). To rebuild the stack yourself, see
[`standup.md`](standup.md).

---

## What it is, in one paragraph

Terraform builds a VPC, a **private** EKS cluster and a **private** RDS PostgreSQL instance in
one AWS account, and runs an uptime monitor on them: a public status board where anyone can add
a website and the cluster checks it every 1 to 60 minutes. Only the app's load balancer is
reachable from the internet, behind WAF. Everything an operator uses (the Kubernetes API, Argo
CD, Grafana) is private and reached through an SSM tunnel with the operator's own IAM identity.
Infrastructure changes go through pull requests and an approval-gated CI apply; the cluster is
GitOps through Argo CD. Monitoring data is stored outside the cluster.

---

## Requirements → evidence

| Asked for | Where to look | How to check |
|---|---|---|
| VPC, private subnets, NAT | [`terraform/modules/network`](../terraform/modules/network) | Three subnet tiers; the database tier has no route to the internet |
| EKS cluster | [`terraform/modules/eks-cluster`](../terraform/modules/eks-cluster) | Private API endpoint only, access entries instead of `aws-auth`, Secrets encrypted with KMS, audit log on |
| RDS | [`terraform/modules/database`](../terraform/modules/database) | `publicly_accessible = false`, KMS, `rds.force_ssl = 1`, password managed and rotated by RDS |
| A working app on the cluster | [`app/`](../app), [`deploy/charts/uptime`](../deploy/charts/uptime) | Open the board, add a site; it reads and writes RDS |
| Secure by default | README, [Security baseline](../README.md#security-baseline-how-each-requirement-is-met) | One row per requirement, with the file that implements it |
| Least privilege IAM | IRSA roles in each module; [`bootstrap/github-oidc.tf`](../bootstrap/github-oidc.tf) | `scripts/check-ci-permissions.sh`: 42 simulated allow/deny cases against the live CI roles |
| Secrets handling | `manage_master_user_password` in `database`; [`addons/argocd-admin.tf`](../addons/argocd-admin.tf) | No secret in git, images or manifests; `gitleaks` runs on every PR |
| Remote state | [`bootstrap/main.tf`](../bootstrap/main.tf) | S3 + SSE-KMS, versioning, TLS-only policy, native lock file |
| Observability | [`terraform/modules/observability`](../terraform/modules/observability), [`managed-prometheus`](../terraform/modules/managed-prometheus), [`addons/`](../addons) | Alarms → email, Managed Prometheus, external canary, Grafana dashboard; [`runbook.md`](runbook.md) entry per alarm |
| CI/CD | [`.github/workflows`](../.github/workflows) | PR: lint, scan, test, plan comment. Merge: approval in `production`, then apply only if the plan matches |
| Reusable code | Eight modules with explicit inputs and outputs | Everything environment-specific is a variable; ARNs use `aws_partition` (works in GovCloud) |
| Teardown | [`scripts/destroy.sh`](../scripts/destroy.sh) | Measured: about 13 minutes, no orphaned load balancers |

---

## Things worth checking yourself

No AWS access needed:

```bash
make test                                   # app unit tests (SSRF guard, SLO maths, claims)
make lint                                   # fmt, tflint, checkov: the same checks as CI
helm template deploy/charts/uptime          # the manifests Argo CD applies
```

On the live board (the URL is shared separately; the repository is public, so it is not here):

- Add a public site and watch its strip fill in within a minute.
- Add `http://169.254.169.254/`: WAF answers 403. Behind it, the checker refuses non-public
  addresses, and NetworkPolicy blocks the metadata address: three layers.
- `http://` redirects to `https://`; TLS 1.3.

During a live session, with operator access:

- `make incident MODE=down`: the board turns red within a minute, and the `monitor-down` email
  arrives in about 2–3 minutes. `MODE=ok` recovers it and sends an OK email.
- Argo CD self-heal: scale the app with `kubectl` and watch Argo CD revert it.
- Grafana: the "Uptime board" dashboard, over Managed Prometheus and CloudWatch.
- `terraform plan` on both layers: no changes (no drift).

---

## Design decisions and trade-offs

| Decision | Why | Cost of the choice |
|---|---|---|
| Private EKS API + SSM jump host | No control plane on the internet; no SSH, no inbound rules; kubectl still authenticates as the person | One more step (`make tunnel`) for operators |
| Argo CD for the cluster, Terraform for AWS | Each tool owns what it is good at; cluster drift is reverted continuously | Two places to look; values that name the account come from Terraform outputs, not git |
| Approval-gated CI apply with a plan digest check | The person approving sees exactly what will change; nothing else can be applied | Merges need a human approval step |
| Monitoring outside the cluster | An alarm must not fail together with what it watches | A little AWS cost (Managed Prometheus, canary) |
| Admin UIs private, no SSO | Their local logins have no MFA; the only identity provider in reach is the organization's corporate directory | Port-forward access only. The production design (Cognito + TOTP MFA + OIDC + read-only roles) is in the README exceptions |
| x86 `t3.medium`, single NAT, single-AZ RDS | The account's SCP forbids Graviton and larger types; cost | Each one is a variable away from the production setting (README exceptions table) |

---

## Found while building, and fixed

Real problems hit during the build, each with its fix in the git history. The
[walkthrough](walkthrough.md#5-things-that-broke-and-what-they-taught-me) tells them as stories.

- A managed EKS add-on upgrade began injecting an init container that Pod Security rejects:
  add-ons are now pinned and upgraded through reviewed PRs.
- Topology spread counted old-revision pods during rollouts: fixed with `matchLabelKeys`.
- CI permission gaps: an IAM-simulator test suite now runs before policy changes are applied.
- The timed teardown and rebuild (2026-11-02) found two ordering bugs: Argo CD Applications have
  to be deleted before their projects, and a namespace `import` block broke the add-ons on a
  new cluster. Both are fixed.

---

## Next steps with more time

Listed in the README's [TODO](../README.md#todo--known-gaps): traces to X-Ray, nightly drift
detection, SLO burn-rate alerts, autoscaling, a least-privilege database role, digest-pinned
actions and images.
