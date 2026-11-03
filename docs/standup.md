# Standing it up, end to end

Every command, in order, from an empty AWS account to a verified, running stack, and back down.
One operator, one laptop. Measured on 2026-11-02: **~19 minutes** from `make up` to all apps
Healthy, plus ~5 minutes for the canary and alarms to settle; teardown ~13 minutes.

Placeholders: `<owner>/<repo>` is the GitHub repository, `<domain>` the app's hostname (for
example `app.demo.example.com`), `<zone>` the delegated DNS zone (`demo.example.com`),
`<profile>` your AWS CLI profile. Keep real values out of this public repository: copy them into
`private/cheatsheet.md`, which git ignores.

| Phase | When | Time |
|---|---|---|
| [0. Tools and access](#0-tools-and-access) | Once per laptop | 10 min |
| [1. Bootstrap](#1-bootstrap-once-per-account) | Once per account | 5 min + DNS delegation |
| [2. GitHub CI](#2-github-ci-once-per-repository) | Once per repository | 5 min |
| [3. Main stack](#3-main-stack) | Every build | 15 min |
| [4. Add-ons and the app](#4-add-ons-and-the-app) | Every build | 3 min |
| [5. Verify](#5-verify) | Every build | 5–8 min |
| [6. Day to day](#6-day-to-day) | | |
| [7. Tear down](#7-tear-down) | | 13 min |
| [8. When something goes wrong](#8-when-something-goes-wrong) | | |

---

## 0. Tools and access

```bash
brew install terraform awscli kubectl helm jq gh tflint checkov
brew install --cask session-manager-plugin docker   # or: brew install colima docker && colima start
```

Versions used: Terraform 1.14, AWS CLI 2.34, kubectl 1.37, session-manager-plugin 1.2, Helm 4.3.

```bash
aws configure --profile <profile>          # or aws configure sso; region us-east-1
export AWS_PROFILE=<profile>
aws sts get-caller-identity                 # the identity that will own the cluster
gh auth login                               # as the repository owner
git clone https://github.com/<owner>/<repo>.git && cd <repo>
```

Everything below runs from the repository root with `AWS_PROFILE` exported.

> **kubectl safety.** The Makefile always uses the repo-local `.kube/config`. When you run
> `kubectl` yourself, first `export KUBECONFIG=$PWD/.kube/config`, or it uses whatever your
> global context is.

---

## 1. Bootstrap (once per account)

Creates the encrypted state bucket, the delegated DNS zone, the GitHub OIDC roles for CI and
the permissions boundary for workload roles. Its own state stays local, in
`bootstrap/terraform.tfstate` (gitignored): back it up.

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
gh api repos/<owner>/<repo> --jq '.owner.id, .id'                  # → github_owner_id, github_repository_id
gh api repos/<owner>/<repo>/actions/oidc/customization/sub          # immutable subjects in use?
$EDITOR bootstrap/terraform.tfvars                                  # dns_zone_name = "<zone>", github_repository, the IDs

make bootstrap                    # init + apply (review the plan), then writes terraform/backend.hcl
terraform -chdir=bootstrap output dns_name_servers
```

**DNS delegation:** at whoever hosts the parent domain, create an `NS` record for `<zone>` with
those four name servers. Check:

```bash
dig +short NS <zone>              # must list the four awsdns servers
```

---

## 2. GitHub CI (once per repository)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
#   admin_cidrs     = ["<your IP>/32"]          curl -s https://checkip.amazonaws.com
#   cluster_admins  = { you = "<your IAM ARN>" } aws sts get-caller-identity --query Arn --output text
#   domain_name     = "<domain>"
#   route53_zone_id = "<zone id>"                terraform -chdir=bootstrap output -raw dns_zone_id
#   alert_email     = "<your email>"
```

Secrets the workflows read (values never appear in logs):

```bash
R=<owner>/<repo>
terraform -chdir=bootstrap output -raw github_plan_role_arn  | gh secret set AWS_PLAN_ROLE_ARN -R $R
gh secret set TF_BACKEND_CONFIG -R $R < terraform/backend.hcl
gh secret set TF_VARS           -R $R < terraform/terraform.tfvars
```

The `production` environment: you approve every apply, and only `main` may deploy.

```bash
MY_ID=$(gh api user --jq .id)
gh api -X PUT repos/$R/environments/production --input - <<EOF
{"reviewers": [{"type": "User", "id": $MY_ID}], "prevent_self_review": false, "wait_timer": 0,
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST repos/$R/environments/production/deployment-branch-policies -f name=main -f type=branch
terraform -chdir=bootstrap output -raw github_apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN -R $R --env production
```

Optional, proves the CI roles' limits with the IAM policy simulator (42 cases):

```bash
scripts/check-ci-permissions.sh
```

> Whenever `terraform.tfvars` changes, update the `TF_VARS` secret too, or CI plans with the
> old values.

---

## 3. Main stack

VPC, EKS, RDS, jump host, ECR, WAF, certificate, Managed Prometheus, alarms, canary.

```bash
make up                           # init → plan → apply; ~15 minutes
```

The first build runs locally (you are the cluster admin). After that, changes to `terraform/`
go through pull requests and the CI apply (section 6).

**Confirm the alert email:** AWS sends "AWS Notification - Subscription Confirmation" to
`alert_email`. Click the link, or alarms never reach you. Check:

```bash
aws sns list-subscriptions-by-topic --topic-arn "$(terraform -chdir=terraform output -raw alerts_topic_arn)" \
  --query 'Subscriptions[].SubscriptionArn' --output text      # an ARN, not PendingConfirmation
```

---

## 4. Add-ons and the app

The EKS API is private. **Terminal 1**, leave it running:

```bash
make tunnel                       # SSM port forward: 127.0.0.1:8443 → private EKS API
```

**Terminal 2:**

```bash
make kubeconfig && export KUBECONFIG=$PWD/.kube/config
kubectl get nodes                 # two Ready nodes
```

The app image. `make down` deletes the image registry, so a new stack starts with an empty
one. Pick one:

```bash
scripts/image.sh restore          # if you ran `scripts/image.sh save` before the teardown: same digest, no PR
# or
make release                      # build, scan, push; pins a new digest in values.yaml → commit, PR, merge
```

Then Argo CD and everything it deploys:

```bash
make addons                       # Argo CD, then its apps: LB controller, ExternalDNS, ADOT, Grafana, the app
kubectl -n argocd get applications -w          # wait for 5× Synced / Healthy (about a minute)
```

---

## 5. Verify

```bash
make status                                        # apps, pods (one per node), ingress, network policies
curl -sI https://<domain>/ | head -1               # HTTP/2 200
curl -s https://<domain>/api/monitors | jq '.monitors[] | {name, ok: .last.ok}'
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"url":"http://169.254.169.254/"}' https://<domain>/api/monitors      # 403 (WAF)
scripts/ssrf-probe.sh https://<domain>             # refused: 25  not refused: 0
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/metrics   # 404: in-cluster only
aws s3 ls "s3://$(terraform -chdir=terraform output -raw alb_logs_bucket)/alb/" --recursive | tail -2   # ALB logs, every 5 min

aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
aws synthetics get-canary-runs --name sre-demo-board --max-results 3 \
  --query 'CanaryRuns[].[Timeline.Started,Status.State]' --output text

terraform -chdir=terraform plan -detailed-exitcode >/dev/null; echo $?          # 0 = no drift
terraform -chdir=addons plan -detailed-exitcode -var api_server_url=https://127.0.0.1:8443 >/dev/null; echo $?
```

Expect a few minutes of noise right after a build, which then clears on its own:

- **Canary runs fail** until DNS points at the new load balancer.
- **`external-down`, `no-running-pods`, `telemetry-silent` or `monitor-down` sit in ALARM**
  until they have data.

All 12 alarms should be `OK` within ~10 minutes.

Grafana and Argo CD (tunnel running):

```bash
make grafana-password && make grafana     # http://localhost:3000, user admin
make argocd-password  && make argocd      # https://localhost:8080, user admin (self-signed certificate)
```

---

## 6. Day to day

| Task | Commands |
|---|---|
| Change infrastructure | Edit `terraform/`, open a PR → read the plan comment → merge → approve in `production` (Actions tab, or `gh api -X POST repos/$R/actions/runs/<run id>/pending_deployments -F "environment_ids[]=$(gh api repos/$R/environments/production --jq .id)" -f state=approved -f comment=ok`) |
| Release the app | `make release` → commit `values.yaml` → PR → merge; Argo CD deploys it |
| Roll back the app | Revert the release PR |
| Change add-ons or dashboards | Edit `addons/` → `make addons` (tunnel running) → PR |
| Incident drill | `make incident MODE=down`, then `make incident MODE=ok` |
| Rotate an admin password | `terraform -chdir=addons apply -var api_server_url=https://127.0.0.1:8443 -replace=random_password.argocd_admin` (or `grafana_admin`) |
| Emergency public API | `eks_public_access = true` in tfvars + `TF_VARS`, apply, then `DIRECT=1 make kubeconfig` |
| Alarms and what to do | [`runbook.md`](runbook.md) |

---

## 7. Tear down

```bash
scripts/image.sh save             # keeps the pinned image (it lives in .image-backup/, gitignored)
make tunnel                       # terminal 1: destroy.sh needs the cluster to remove the load balancer
make down                         # terminal 2: answer "yes" twice (add-ons, then the main stack)
```

`destroy.sh` deletes the Argo CD Applications first, so their finalizers remove the Ingress, the
ALB and every add-on before the cluster goes. The bootstrap layer stays, so a rebuild starts at
section 3.

What survives a teardown, on purpose or harmlessly:

- **Kept on purpose:** the bootstrap layer (state bucket, DNS zone, CI roles).
- **Deleted with the stack:** the ALB access logs (the bucket empties itself on destroy). Copy them
  out first if you need them: `aws s3 sync s3://$(terraform -chdir=terraform output -raw alb_logs_bucket) ./alb-logs`.
- **Left behind, harmless:** ExternalDNS's `A`/`AAAA`/`TXT` records point at the deleted load
  balancer until the next build takes them over. Synthetics also leaves its canary's
  `/aws/lambda/cwsyn-…` log group.

---

## 8. When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `make tunnel`: `TargetNotConnected` | The jump host's SSM agent is not online yet (new instance) | Wait a minute; `aws ssm describe-instance-information` |
| kubectl hits the wrong cluster | `KUBECONFIG` not exported | `export KUBECONFIG=$PWD/.kube/config` |
| `connection refused 127.0.0.1:8443` | The tunnel closed (idle timeout or the jump host was replaced) | Run `make tunnel` again |
| The board does not resolve on your laptop right after a build | Your resolver cached "no such host" from before the record existed | `dig +short <domain> @1.1.1.1` works → wait, or `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| App pods `ImagePullBackOff` | The pinned digest is not in the new ECR | `scripts/image.sh restore`, or `make release` + PR |
| `make down` hangs on `helm_release.argocd_apps` | An Application lost its AppProject before its finalizer ran (fixed in `destroy.sh`) | `kubectl -n argocd get applications`; recreate the project, or remove the finalizer |
| CI apply fails with `AccessDenied` | The CI role lacks a permission | Add it in `bootstrap/github-oidc.tf`, simulate with `scripts/check-ci-permissions.sh`, `terraform -chdir=bootstrap apply` |
| CI plan differs from your local plan | `TF_VARS` secret is stale | `gh secret set TF_VARS -R $R < terraform/terraform.tfvars` |
| No alarm emails | Subscription not confirmed | Section 3 |
