#!/usr/bin/env bash
# Try to make the board check addresses it must never reach (SSRF), from the
# outside, and show which layer refused each one:
#
#   403  WAF, at the load balancer
#   400  the app's checker (the reason is printed)
#   429  WAF's limit on adding sites (also a refusal)
#
# Anything else is a failure: a 2xx means a monitor was created, so the
# script deletes it again with the returned token and exits non-zero.
#
#   scripts/ssrf-probe.sh https://<domain>
set -uo pipefail

BASE="${1:?usage: scripts/ssrf-probe.sh https://<domain>}"
BASE="${BASE%/}"

URLS=(
  # Instance metadata, in its usual and disguised forms
  "http://169.254.169.254/latest/meta-data/"
  "http://[::ffff:169.254.169.254]/"
  "http://[fd00:ec2::254]/"
  "http://169.254.169.254.nip.io/"
  "http://metadata.google.internal/"
  # Loopback and private ranges
  "http://127.0.0.1/"
  "http://127.1/"
  "http://0x7f.1/"
  "http://2130706433/"
  "http://017700000001/"
  "http://0.0.0.0/"
  "http://[::1]/"
  "http://[0:0:0:0:0:ffff:7f00:1]/"
  "http://localhost/"
  "http://localtest.me/"
  "http://10.0.0.1/"
  "http://172.17.0.1/"
  "http://192.168.1.1/"
  "http://100.64.0.1/"
  # Cluster-internal names
  "http://kubernetes.default.svc/"
  "http://db.internal/"
  # Other schemes, ports and credentials
  "file:///etc/passwd"
  "gopher://127.0.0.1:6379/"
  "https://example.com:22/"
  "https://example.com@127.0.0.1/"
)

pass=0; fail=0
body=$(mktemp); trap 'rm -f "$body"' EXIT
for url in "${URLS[@]}"; do
  payload=$(jq -cn --arg u "$url" '{url: $u, method: "GET", interval: 300, name: "ssrf probe"}')
  code=$(curl -s -o "$body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$BASE/api/monitors")
  case "$code" in
    403) layer="WAF"; reason="" ;;
    429) layer="WAF add limit"; reason="" ;;
    400) layer="app"; reason=$(jq -r '.error // empty' "$body" 2>/dev/null) ;;
    *)   layer="NOT REFUSED"; reason="" ;;
  esac
  if [[ "$layer" == "NOT REFUSED" ]]; then
    fail=$((fail + 1))
    id=$(jq -r '.id // empty' "$body" 2>/dev/null); token=$(jq -r '.token // empty' "$body" 2>/dev/null)
    [[ -n "$id" && -n "$token" ]] && curl -s -o /dev/null -X DELETE -H "X-Delete-Token: $token" "$BASE/api/monitors/$id"
  else
    pass=$((pass + 1))
  fi
  printf '%-40s %s  %-13s %s\n' "$url" "$code" "$layer" "$reason"
done

echo "refused: $pass  not refused: $fail"
[[ $fail -eq 0 ]]
