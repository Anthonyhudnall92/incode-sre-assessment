#!/usr/bin/env bash
# Tear down in the right order.
#
# The ALB and its security groups are created by the AWS Load Balancer
# Controller, not Terraform. If the cluster is destroyed first they are
# orphaned and block VPC deletion. So: delete the app namespace, wait for the
# controller to remove the ALB, then terraform destroy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"

TF_OUT="$(terraform -chdir="$TF_DIR" output -json 2>/dev/null || echo '{}')"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }

REGION="$(out region)"
CLUSTER="$(out cluster_name)"
NAMESPACE="$(out app_namespace)"

if [[ -n "$CLUSTER" ]] && aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  echo "==> Deleting namespace $NAMESPACE (removes the Ingress and its ALB)"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=300s || true

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

echo "==> terraform destroy"
terraform -chdir="$TF_DIR" destroy "$@"
