#!/usr/bin/env bash
# Tear down in the right order.
#
# The ALB and its security groups are created by the AWS Load Balancer
# Controller, not Terraform. If the cluster is destroyed first they are
# orphaned and block VPC deletion. So: delete the app's Argo CD Application
# (its finalizer deletes the Ingress), wait for the controller to remove the
# ALB, destroy the add-ons, then the main stack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
# Repo-local kubeconfig: never touch the global one (and its current context).
export KUBECONFIG="$ROOT/.kube/config"

TF_OUT="$(terraform -chdir="$TF_DIR" output -json 2>/dev/null || echo '{}')"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }

REGION="$(out region)"
CLUSTER="$(out cluster_name)"
NAMESPACE="$(out app_namespace)"
APP="$(out app_name)"

if [[ -n "$CLUSTER" ]] && aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
  # Deleting the namespace directly would not stick: Argo CD would recreate it.
  if kubectl -n argocd get application "$APP" >/dev/null 2>&1; then
    echo "==> Deleting Argo CD application $APP (removes the Ingress and its ALB)"
    kubectl -n argocd delete application "$APP" --wait=true --timeout=300s || true
  else
    echo "==> Deleting namespace $NAMESPACE (removes the Ingress and its ALB)"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=300s || true
  fi

  echo "==> Waiting for controller-managed load balancers to disappear"
  for _ in $(seq 1 60); do
    COUNT="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
      --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
      --query 'length(ResourceTagMappingList)' --output text)"
    [[ "$COUNT" == "0" ]] && break
    sleep 10
  done
fi

# Add-ons live in the cluster, so they go before it. Skipped if this layer
# was never initialised.
if [[ -n "$CLUSTER" ]] && aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  echo "==> terraform destroy (add-ons)"
  terraform -chdir="$ROOT/addons" init -input=false -backend-config="$TF_DIR/backend.hcl" \
    -backend-config=key=sre-demo/addons.tfstate >/dev/null
  terraform -chdir="$ROOT/addons" destroy "$@"
fi

echo "==> terraform destroy (main stack)"
terraform -chdir="$TF_DIR" destroy "$@"
