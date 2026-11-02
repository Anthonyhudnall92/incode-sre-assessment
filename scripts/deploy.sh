#!/usr/bin/env bash
# Build, scan, push and deploy the demo app to the cluster created by Terraform.
#
#   scripts/deploy.sh                 build + push a new image, then deploy
#   SKIP_BUILD=1 scripts/deploy.sh    redeploy manifests with the current image
#   ALLOW_CRITICAL=1 ...              deploy even if ECR reports CRITICAL CVEs
#
# Requires: terraform, aws CLI v2, docker (buildx), kubectl, jq, envsubst.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
RENDER_DIR="$ROOT/rendered" # gitignored
# Repo-local kubeconfig: never touch the global one (and its current context).
export KUBECONFIG="$ROOT/.kube/config"

for bin in terraform aws docker kubectl jq envsubst; do # envsubst: brew install gettext
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

TF_OUT="$(terraform -chdir="$TF_DIR" output -json)"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }

export AWS_REGION="$(out region)"
CLUSTER="$(out cluster_name)"
REPO_URL="$(out ecr_repository_url)"
REPO_NAME="${REPO_URL#*/}"
REGISTRY="${REPO_URL%%/*}"

export APP_NAME="$(out app_name)"
export APP_NAMESPACE="$(out app_namespace)"
export APP_ROLE_ARN="$(out app_role_arn)"
export DB_HOST="$(out db_host)"
export DB_PORT="$(out db_port)"
export DB_NAME="$(out db_name)"
export DB_SECRET_ARN="$(out db_secret_arn)"
export VPC_CIDR="$(out vpc_cidr)"
CERT_ARN="$(out certificate_arn)"
WAF_ARN="$(out waf_web_acl_arn)"
DOMAIN="$(out domain_name)"
ZONE_ID="$(out route53_zone_id)"

echo "==> Configuring kubectl for $CLUSTER"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null

# --- Image ------------------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # <YYYYMMDD>-<git short sha> (CONTRIBUTING.md). Tags are immutable in ECR,
  # so an existing tag is reused rather than rebuilt.
  TAG="${TAG:-$(date -u +%Y%m%d)-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)}"
  PLATFORM="${IMAGE_PLATFORM:-linux/amd64}" # must match node_ami_type
  if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO_NAME" \
      --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "==> $REPO_URL:$TAG already exists; reusing it"
  else
    echo "==> Building $REPO_URL:$TAG ($PLATFORM)"
    aws ecr get-login-password --region "$AWS_REGION" \
      | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
    docker buildx build --platform "$PLATFORM" --provenance=false \
      -t "$REPO_URL:$TAG" --push "$ROOT/app"
  fi

  echo "==> Waiting for ECR scan"
  aws ecr wait image-scan-complete --region "$AWS_REGION" \
    --repository-name "$REPO_NAME" --image-id imageTag="$TAG"
  CRITICAL="$(aws ecr describe-image-scan-findings --region "$AWS_REGION" \
    --repository-name "$REPO_NAME" --image-id imageTag="$TAG" \
    --query 'imageScanFindings.findingSeverityCounts.CRITICAL' --output text)"
  if [[ "$CRITICAL" != "None" && "$CRITICAL" != "0" && "${ALLOW_CRITICAL:-0}" != "1" ]]; then
    echo "ECR scan found $CRITICAL CRITICAL vulnerabilities; refusing to deploy (ALLOW_CRITICAL=1 to override)" >&2
    exit 1
  fi
  DIGEST="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO_NAME" \
    --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text)"
else
  DIGEST="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO_NAME" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageDigest' --output text)"
fi
export APP_IMAGE="$REPO_URL@$DIGEST"
echo "==> Image: $APP_IMAGE"

# --- Render manifests -----------------------------------------------------------
export DB_SUBNET_CIDRS="$(jq -r '.database_subnet_cidrs.value | join(" ")' <<<"$TF_OUT")"
export CERT_ARN WAF_ARN
"$ROOT/scripts/render-manifests.sh" "$RENDER_DIR"

echo "==> Validating manifests (server-side dry run)"
kubectl apply -f "$RENDER_DIR/00-namespace.yaml"
kubectl apply --dry-run=server -f "$RENDER_DIR" >/dev/null

echo "==> Applying"
kubectl apply -f "$RENDER_DIR"
kubectl -n "$APP_NAMESPACE" rollout status "deployment/$APP_NAME" --timeout=300s

echo "==> Waiting for ALB hostname"
HOST=""
for _ in $(seq 1 60); do
  HOST="$(kubectl -n "$APP_NAMESPACE" get ingress "$APP_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$HOST" ]] && break
  sleep 5
done
[[ -z "$HOST" ]] && { echo "ALB not ready yet; check: kubectl -n $APP_NAMESPACE describe ingress $APP_NAME" >&2; exit 1; }

if [[ -n "$DOMAIN" && -n "$ZONE_ID" ]]; then
  echo "==> Pointing $DOMAIN at the ALB"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$(jq -n \
    --arg name "$DOMAIN" --arg host "$HOST" \
    '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:"CNAME",TTL:60,ResourceRecords:[{Value:$host}]}}]}')" >/dev/null
  echo "App: https://$DOMAIN/"
else
  echo "App: http://$HOST/"
fi
