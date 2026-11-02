#!/usr/bin/env bash
# Plan the main stack and summarise it without values: which resources change
# and how, never what they change to. The full plan is never printed, because
# this repository's logs are public.
#
# Writes: terraform/tfplan, $RUNNER_TEMP/plan-summary.md (also appended to the
#         job summary), and step outputs:
#           changes = true|false
#           digest  = sha256 of the sorted "action address" list, so a later
#                     job can check it applies exactly what was reviewed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="${RUNNER_TEMP:-/tmp}"
REDACT="$TMP/redact.txt"
SUMMARY="$TMP/plan-summary.md"
cd "$ROOT/terraform"

set +e
terraform plan -input=false -lock-timeout=5m -detailed-exitcode -no-color -out=tfplan >"$TMP/plan.log" 2>&1
status=$?
set -e
if [[ $status -eq 1 ]]; then
  # Only the error blocks; values in them are masked by terraform-config.sh.
  echo "terraform plan failed:" >&2
  grep -A12 -E '^(│ )?Error' "$TMP/plan.log" >&2 || tail -20 "$TMP/plan.log" >&2
  exit 1
fi

changes="$(terraform show -json tfplan | jq -r '
  .resource_changes[]
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | (.change.actions | if . == ["create"] then "create"
                       elif . == ["update"] then "update"
                       elif . == ["delete"] then "destroy"
                       else "replace" end) + " " + .address' | sort)"

redact() {
  [[ -s "$REDACT" ]] || { cat; return; }
  REDACT="$REDACT" perl -pe 'BEGIN { open my $f, "<", $ENV{REDACT}; chomp(@v = <$f>) }
                              for my $v (@v) { s/\Q$v\E/***/g }'
}

{
  echo "### Terraform plan: main stack"
  echo
  if [[ -z "$changes" ]]; then
    echo "No changes. Infrastructure matches the configuration."
  else
    for action in create update replace destroy; do
      printf '%s: %s · ' "$action" "$(grep -c "^$action " <<<"$changes" || true)"
    done | sed 's/ · $//'
    echo
    echo
    echo "| Action | Resource |"
    echo "|---|---|"
    while read -r action address; do
      echo "| $action | \`$address\` |"
    done <<<"$changes"
  fi
  echo
  echo "<sub>Values are hidden because this repository is public. Commit $(git rev-parse --short HEAD).</sub>"
} | redact >"$SUMMARY"

cat "$SUMMARY" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "changes=$([[ -n "$changes" ]] && echo true || echo false)"
  echo "digest=$(printf '%s' "$changes" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
