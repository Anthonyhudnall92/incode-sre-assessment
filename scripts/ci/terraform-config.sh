#!/usr/bin/env bash
# Write terraform/backend.hcl and terraform/terraform.tfvars from GitHub
# secrets, and mask every value in them. This repository is public, so its
# workflow logs are too: an account ID, domain, IP or email must never show.
#
# Env:    TF_BACKEND_CONFIG, TF_VARS (secret file contents)
# Writes: terraform/backend.hcl, terraform/terraform.tfvars, and
#         $RUNNER_TEMP/redact.txt: the same values, for scrubbing anything
#         posted outside the log (masking only covers logs, not PR comments).
set -euo pipefail

: "${TF_BACKEND_CONFIG:?TF_BACKEND_CONFIG secret is not set}"
: "${TF_VARS:?TF_VARS secret is not set}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REDACT="${RUNNER_TEMP:-/tmp}/redact.txt"

printf '%s\n' "$TF_BACKEND_CONFIG" >"$ROOT/terraform/backend.hcl"
printf '%s\n' "$TF_VARS" >"$ROOT/terraform/terraform.tfvars"

{
  # Every quoted value except the region, which is public anyway.
  grep -ohE '"[^"]+"' "$ROOT/terraform/backend.hcl" "$ROOT/terraform/terraform.tfvars" |
    tr -d '"' | awk 'length($0) >= 6 && $0 != "us-east-1"'
  # Account IDs wherever they appear (inside ARNs and the bucket name).
  grep -ohE '[0-9]{12}' "$ROOT/terraform/backend.hcl" "$ROOT/terraform/terraform.tfvars" || true
  # The bare address of each CIDR.
  grep -ohE '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]+' "$ROOT/terraform/terraform.tfvars" | cut -d/ -f1 || true
} | sort -u >"$REDACT"

while IFS= read -r value; do
  echo "::add-mask::${value}"
done <"$REDACT"

echo "wrote backend.hcl and terraform.tfvars; masked $(wc -l <"$REDACT" | tr -d ' ') values"
