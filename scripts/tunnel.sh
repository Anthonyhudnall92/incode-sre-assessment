#!/usr/bin/env bash
# Forward 127.0.0.1:${TUNNEL_PORT:-8443} to the private EKS API through the
# SSM jump host. Leave it running; kubectl, helm and `make addons` use it.
#
# There is no SSH or inbound rule involved: the SSM agent on the jump host
# dials out to Systems Manager, and this session rides on that. You still
# authenticate to Kubernetes as yourself (your IAM identity, via the
# kubeconfig); the jump host has no Kubernetes access.
#
# Requires: aws CLI v2, session-manager-plugin (brew install --cask session-manager-plugin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${TUNNEL_PORT:-8443}"

command -v session-manager-plugin >/dev/null || {
  echo "missing session-manager-plugin: brew install --cask session-manager-plugin" >&2
  exit 1
}

TF_OUT="$(terraform -chdir="$ROOT/terraform" output -json)"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }

REGION="$(out region)"
INSTANCE="$(out jump_host_instance_id)"
API_HOST="$(out cluster_endpoint)"
API_HOST="${API_HOST#https://}"

echo "==> EKS API on https://127.0.0.1:$PORT (Ctrl-C to close)"
exec aws ssm start-session --region "$REGION" --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$API_HOST,portNumber=443,localPortNumber=$PORT"
