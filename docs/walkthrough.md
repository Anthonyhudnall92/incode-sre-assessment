# Interview walkthrough

Notes for presenting the running stack: what to show, in what order, how to explain each part,
and the trade-offs behind it. The [README](../README.md) has the reference detail (security
baseline, exceptions, threat model); this page is the narrative.

---

## 1. Two-minute overview

> "Terraform on AWS: a VPC, a private EKS cluster and a private RDS instance, running an
> uptime-monitoring board that anyone can use. Only the app is public, behind WAF. Everything I
> operate through (the Kubernetes API, Argo CD, Grafana) is private and reached through SSM with
> my own IAM identity. Infrastructure changes go through PRs with an approval-gated CI apply;
> cluster state is GitOps through Argo CD. Observability lives outside the cluster, so it
> survives the cluster, and an external canary checks the public path like a visitor."

Show the README's architecture diagram while saying it.

---

## 2. Demo script (about 20 minutes)

Before the call: `make tunnel` running in one terminal (see the checklist at the end).

| # | Show | Say |
|---|---|---|
| 1 | **The board**, `https://<domain>/` | The app: shared uptime board, 7-day SLO 99.9 %, error budget, p95. Add a site live. |
| 2 | An SSRF attempt: add `http://169.254.169.254/` | Blocked by WAF's SSRF rule; behind it the checker refuses non-public addresses, and NetworkPolicy is the third layer. |
| 3 | **Grafana**: `make grafana` → localhost:3000 | Data comes from Managed Prometheus (ADOT collector, SigV4) and CloudWatch; Grafana is just the view. The canary panel is checked from outside the VPC. |
| 4 | **Incident drill**: `make incident MODE=down` | Board turns red within a minute, error budget spent; `monitor-down` emails in about 2–3 minutes (2 of 3 failed checks, so one blip does not page). Then `MODE=ok` → recovery email. The switch only listens inside the pod, so it needs `kubectl exec`: IAM + RBAC. |
| 5 | **Argo CD**: `make argocd` → localhost:8080 | Five apps, Synced and Healthy. Self-heal: `kubectl -n uptime scale deploy/uptime --replicas=1` is reverted in seconds. |
| 6 | **A change through the pipeline**: edit e.g. `log_retention_days`, open a PR | Plan comment (addresses only, values hidden: public repo), merge, approve in `production`, apply only if the change list matches what was reviewed. |
| 7 | **Security posture**: README "What is exposed" and the threat-model table | One public endpoint; per-component blast radius. |

---

## 3. Explaining each part

| Component | What and why | Alternative / bigger version |
|---|---|---|
| **VPC** | 3 tiers in 2 AZs: public (ALB, NAT), private (nodes), database (no internet route). One NAT for cost. | NAT per AZ; VPC endpoints instead of NAT for AWS APIs. |
| **EKS** | 1.34, private API only, access entries (no `aws-auth`), Secrets envelope-encrypted with KMS, audit log on. Managed node group, 2× t3.medium (org SCP forbids larger and Graviton). VPC CNI prefix delegation: 110 pods per node instead of 17. | Karpenter, Graviton, Security Groups for Pods. |
| **Private API + jump host** | SSM port forward through a t3.micro with no inbound rules, no public IP, SSM-only role; kubectl still authenticates as *me*. Break-glass `eks_public_access`. | VPN or a CI runner inside the VPC; SSM VPC endpoints. |
| **RDS** | PostgreSQL 17, private, KMS, `force_ssl`; the password is RDS-managed in Secrets Manager and rotated; app uses `verify-full`. | Multi-AZ, least-privilege app role, IAM DB auth. |
| **App** | Python board + SSRF-safe checker; both replicas share checks via `UPDATE … FOR UPDATE SKIP LOCKED`; non-root, read-only FS, PSA `restricted`; image pinned by digest. | Separate checker deployment, queue, HPA. |
| **Ingress** | ALB (LB Controller, IP targets, readiness gates), ACM TLS 1.3/1.2, WAF (managed rules + rate limit), ExternalDNS for the record. | CloudFront in front, Shield Advanced. |
| **GitOps** | CI: OIDC roles (plan read-only; apply only from the `production` environment), approval gate, digest check, public-safe logs. Cluster: Argo CD from `main`, self-heal and prune. Private values come from Terraform outputs, not git. | Separate accounts per environment; Argo CD ApplicationSets. |
| **Observability** | Managed Prometheus (ADOT), CloudWatch logs/metrics/alarms, Synthetics canary, in-cluster Grafana; alarms → SNS email. Heartbeat dead man's switch. | Burn-rate SLO alerts, traces to X-Ray, PagerDuty routing. |
| **IAM** | Every role scoped and capped by a permissions boundary; CI permissions tested with the IAM simulator (`scripts/check-ci-permissions.sh`). | IAM Access Analyzer policy generation, SCPs per OU. |

---

## 4. Defending the security choices

- **What is exposed?** The ALB, behind WAF. Nothing else: no public API endpoint, no admin UIs.
- **App pod compromised?** Read one DB secret; reach the DB subnets and public HTTPS; nothing in
  the cluster (default-deny NetworkPolicy), no node credentials (IMDS hop limit 1), no K8s token.
- **CI compromised?** It can only change this stack's scoped resources, and only after a human
  approves; it cannot touch state, the CI roles or the boundary.
- **Why are Argo CD and Grafana private?** Their local logins have no MFA, and Argo CD can deploy
  anything into the cluster. The hardened version: a Cognito user pool with mandatory TOTP MFA,
  OIDC login in both, read-only roles for viewers, ALB `authenticate-cognito` plus a WAF
  allowlist. I did not use the organization's IAM Identity Center: it is the corporate
  directory, outside this account's scope.
- **Known exceptions** are in the README table with the production answer for each.

---

## 5. Things that broke, and what they taught me

Real incidents from building this; good answers to "tell me about a time…".

1. **A managed add-on changed a default and blocked every deploy.** The CloudWatch add-on moved
   to v7, which auto-instruments every workload by injecting an init container that fails Pod
   Security `restricted`. Every new app pod was rejected; the old pods kept serving. Fix: turn
   auto-monitor off, opt the app out, and **pin add-on versions** so upgrades are reviewed PRs.
   Lesson: strict admission policy turned a silent risk into a safe, visible stall.
2. **Rollout timeouts that weren't what I thought.** During a rollout a probe saw two timeouts.
   My hypothesis (network-policy agent drops traffic to terminating pods) did **not** reproduce
   under instrumentation (client, ALB target states, EndpointSlices, app logs). The cause: the
   old pods predated the new `preStop` delay. The same instrumentation exposed a real bug:
   topology spread counted old-revision pods, so rollouts left both replicas on one node; fixed
   with `matchLabelKeys: [pod-template-hash]` and proven over two rollouts (0 failures).
3. **CI permission gaps → test before apply.** Several applies failed on missing permissions
   (`MonitorInstances`, singular vs plural `CreateLaunchTemplateVersion`, EKS's dry-run
   `RunInstances`, Synthetics passing roles as itself). I added an IAM-simulator test suite and
   simulate *proposed* policies before applying; it caught the next two gaps before any apply.
4. **ExternalDNS created no record.** `--domain-filter` selects zones, and the app's domain is a
   subdomain of the zone; debug logs showed "no hosted zone matching". Filter on the zone name.
5. **The probe that blamed the site for my laptop's network.** 70 s of timeouts from my laptop
   while in-cluster checks of the public URL passed and the ALB saw only my share of traffic
   disappear. One vantage point cannot tell "site down" from "my network down": hence the
   external canary.
6. **A dead man's switch paged on creation.** The heartbeat alarm treats missing data as
   failure, so it fired before its first data point. The canary alarm instead keeps missing data
   as missing and notifies on `INSUFFICIENT_DATA`: no false page, and a stopped canary is still
   noticed.

---

## 6. Likely live changes

| Ask | How |
|---|---|
| Scale the app | `replicas` in `deploy/charts/uptime/values.yaml` → PR → Argo CD (kubectl would be reverted) |
| Change an alarm | `terraform/modules/observability/main.tf` → PR → plan comment → merge → approve |
| Ship a new app version | `make release` (build, scan, push, pin digest) → PR |
| Roll back | Revert the release PR |
| Rotate the Argo CD / Grafana password | `terraform -chdir=addons apply -replace=random_password.argocd_admin` (or `grafana_admin`) |
| Open the API in an emergency | `eks_public_access = true` (tfvars + `TF_VARS` secret), apply, `DIRECT=1 make kubeconfig` |
| Add a dashboard panel | Edit `addons/dashboards/uptime.json` → `make addons` |

---

## 7. Cost (us-east-1, rough)

About **$9–11/day** while running: EKS control plane ($2.40), 2× t3.medium (~$2), NAT gateway
(~$1.10 + data), ALB (~$0.55), db.t3.micro (~$0.40), jump host (~$0.25), WAF, KMS keys, the
canary (~$0.35), Managed Prometheus and CloudWatch (small at this volume). Tear down between
sessions with `make down`.

---

## 8. Pre-interview checklist

1. `make up`, then `make tunnel` (leave running), `make addons`. Allow ~30 minutes.
2. `make status`: all Argo CD apps Synced and Healthy.
3. CloudWatch: every alarm `OK`; the SNS email subscription is confirmed.
4. Board loads on the domain; the canary's last runs passed.
5. Grafana dashboard shows data; the incident drill target is `MODE=ok`.
6. Rehearse the drill once; keep `make incident MODE=ok` ready.
