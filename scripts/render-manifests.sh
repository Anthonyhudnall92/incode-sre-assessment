#!/usr/bin/env bash
# Render k8s/*.yaml templates into an output directory.
# Used by deploy.sh (real values from Terraform) and by CI (dummy values) so the
# exact manifests that get applied are the ones that get scanned.
#
# Required env: APP_NAME APP_NAMESPACE APP_ROLE_ARN APP_IMAGE DB_HOST DB_PORT
#               DB_NAME DB_SECRET_ARN AWS_REGION VPC_CIDR DB_SUBNET_CIDRS
# Optional env: CERT_ARN WAF_ARN
# Usage:        scripts/render-manifests.sh <output-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:?usage: render-manifests.sh <output-dir>}"

for v in APP_NAME APP_NAMESPACE APP_ROLE_ARN APP_IMAGE DB_HOST DB_PORT DB_NAME DB_SECRET_ARN AWS_REGION VPC_CIDR DB_SUBNET_CIDRS; do
  [[ -n "${!v:-}" ]] || { echo "render-manifests: $v is not set" >&2; exit 1; }
done

if [[ "$APP_IMAGE" != *@sha256:* ]]; then
  echo "render-manifests: APP_IMAGE must be pinned by digest (repo@sha256:...)" >&2
  exit 1
fi

# PostgreSQL egress peers: one ipBlock per database subnet.
DB_EGRESS_PEERS=""
for cidr in $DB_SUBNET_CIDRS; do
  DB_EGRESS_PEERS+="        - ipBlock:"$'\n'"            cidr: ${cidr}"$'\n'
done
export DB_EGRESS_PEERS="${DB_EGRESS_PEERS%$'\n'}"

INGRESS_ANNOTATIONS=""
ann() { INGRESS_ANNOTATIONS+="    $1"$'\n'; }
if [[ -n "${CERT_ARN:-}" ]]; then
  ann "alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}, {\"HTTPS\": 443}]'"
  ann "alb.ingress.kubernetes.io/ssl-redirect: '443'"
  ann "alb.ingress.kubernetes.io/certificate-arn: ${CERT_ARN}"
  ann "alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06"
else
  echo "WARNING: no certificate configured; ALB will serve plain HTTP (documented exception)." >&2
  ann "alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}]'"
fi
if [[ -n "${WAF_ARN:-}" ]]; then
  ann "alb.ingress.kubernetes.io/wafv2-acl-arn: ${WAF_ARN}"
fi
export INGRESS_ANNOTATIONS="${INGRESS_ANNOTATIONS%$'\n'}"

export APP_NAME APP_NAMESPACE APP_ROLE_ARN APP_IMAGE DB_HOST DB_PORT DB_NAME DB_SECRET_ARN AWS_REGION VPC_CIDR
VARS='${APP_NAME} ${APP_NAMESPACE} ${APP_ROLE_ARN} ${APP_IMAGE} ${DB_HOST} ${DB_PORT} ${DB_NAME} ${DB_SECRET_ARN} ${AWS_REGION} ${VPC_CIDR} ${DB_EGRESS_PEERS} ${INGRESS_ANNOTATIONS}'

rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
for f in "$ROOT"/k8s/*.yaml; do
  envsubst "$VARS" <"$f" >"$OUT_DIR/$(basename "$f")"
done
echo "rendered $(ls "$OUT_DIR" | wc -l | tr -d ' ') manifests into $OUT_DIR"
