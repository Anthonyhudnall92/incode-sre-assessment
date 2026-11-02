#!/usr/bin/env bash
# Build, scan and push the app image, then pin its digest in the chart.
#
# Argo CD deploys whatever main says, so this script never touches the
# cluster. Commit the values.yaml change it makes, open a PR, merge it:
# that is the release.
#
#   scripts/release.sh                 build + push (or reuse) the image for HEAD
#   ALLOW_CRITICAL=1 ...               pin even if ECR reports CRITICAL CVEs
#
# Requires: terraform, aws CLI v2, docker (buildx), jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="$ROOT/deploy/charts/uptime/values.yaml"

for bin in terraform aws docker jq; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

TF_OUT="$(terraform -chdir="$ROOT/terraform" output -json)"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }

AWS_REGION="$(out region)"
REPO_URL="$(out ecr_repository_url)"
REPO_NAME="${REPO_URL#*/}"
REGISTRY="${REPO_URL%%/*}"

# <YYYYMMDD>-<git short sha> (CONTRIBUTING.md). Tags are immutable in ECR,
# so an existing tag is reused rather than rebuilt.
TAG="${TAG:-$(date -u +%Y%m%d)-$(git -C "$ROOT" rev-parse --short HEAD)}"
PLATFORM="${IMAGE_PLATFORM:-linux/amd64}" # must match node_ami_type

if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO_NAME" \
    --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "==> $REPO_NAME:$TAG already exists; reusing it"
else
  echo "==> Building $REPO_NAME:$TAG ($PLATFORM)"
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
  echo "ECR scan found $CRITICAL CRITICAL vulnerabilities; not pinning it (ALLOW_CRITICAL=1 to override)" >&2
  exit 1
fi

DIGEST="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO_NAME" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text)"

# A line edit, not yq: yq drops the comments around the key.
[[ "$(grep -c '^  digest: ' "$VALUES")" == 1 ]] || { echo "expected one image digest line in $VALUES" >&2; exit 1; }
sed -i.bak -E "s|^  digest: .*|  digest: \"$DIGEST\"|" "$VALUES" && rm -f "$VALUES.bak"
echo "==> Pinned $TAG ($DIGEST) in ${VALUES#"$ROOT"/}"
echo "    Commit it, open a PR and merge: Argo CD rolls it out from main."
