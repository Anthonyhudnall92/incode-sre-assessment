#!/usr/bin/env bash
# Save the image pinned in the chart before `make down`, and push it back
# after `make up`, byte for byte (same digest), so a rebuild needs no release
# PR. `make down` deletes the ECR repository with every image in it.
#
#   scripts/image.sh save      [dir]   default dir: .image-backup (gitignored)
#   scripts/image.sh restore   [dir]
#
# Uses only the ECR API (no docker), and checks every digest.
# Requires: terraform, aws CLI v2, jq, curl, shasum.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-}"
DIR="${2:-$ROOT/.image-backup}"

TF_OUT="$(terraform -chdir="$ROOT/terraform" output -json)"
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$TF_OUT"; }
REGION="$(out region)"
REPO_URL="$(out ecr_repository_url)"
REPO="${REPO_URL#*/}"

sha() { echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"; }

case "$CMD" in
  save)
    DIGEST="$(sed -nE 's/^ *digest: *"?(sha256:[0-9a-f]+)"?.*/\1/p' "$ROOT/deploy/charts/uptime/values.yaml")"
    mkdir -p "$DIR/blobs"
    aws ecr batch-get-image --region "$REGION" --repository-name "$REPO" \
      --image-ids imageDigest="$DIGEST" --output json > "$DIR/image.json"
    jq -j '.images[0].imageManifest' "$DIR/image.json" > "$DIR/manifest.json"
    jq -r '.images[0].imageManifestMediaType' "$DIR/image.json" > "$DIR/mediatype"
    jq -r '.images[0].imageId.imageTag // empty' "$DIR/image.json" > "$DIR/tag"
    [[ "$(sha "$DIR/manifest.json")" == "$DIGEST" ]] || { echo "manifest digest mismatch" >&2; exit 1; }
    for d in $(jq -r '.config.digest, .layers[].digest' "$DIR/manifest.json"); do
      url="$(aws ecr get-download-url-for-layer --region "$REGION" --repository-name "$REPO" \
        --layer-digest "$d" --query downloadUrl --output text)"
      curl -fsSL -o "$DIR/blobs/${d#sha256:}" "$url"
      [[ "$(sha "$DIR/blobs/${d#sha256:}")" == "$d" ]] || { echo "blob digest mismatch: $d" >&2; exit 1; }
    done
    echo "==> saved $DIGEST to $DIR"
    ;;
  restore)
    DIGEST="$(sha "$DIR/manifest.json")"
    if aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
        --image-ids imageDigest="$DIGEST" >/dev/null 2>&1; then
      echo "==> $DIGEST is already in ECR"
      exit 0
    fi
    for d in $(jq -r '.config.digest, .layers[].digest' "$DIR/manifest.json"); do
      have="$(aws ecr batch-check-layer-availability --region "$REGION" --repository-name "$REPO" \
        --layer-digests "$d" --query 'layers[0].layerAvailability' --output text)"
      [[ "$have" == AVAILABLE ]] && continue
      up="$(aws ecr initiate-layer-upload --region "$REGION" --repository-name "$REPO" --query uploadId --output text)"
      parts="$(mktemp -d)"
      split -b 10485760 "$DIR/blobs/${d#sha256:}" "$parts/p."
      first=0
      for p in "$parts"/p.*; do
        last=$((first + $(wc -c < "$p") - 1))
        aws ecr upload-layer-part --region "$REGION" --repository-name "$REPO" --upload-id "$up" \
          --part-first-byte "$first" --part-last-byte "$last" --layer-part-blob "fileb://$p" >/dev/null
        first=$((last + 1))
      done
      rm -rf "$parts"
      aws ecr complete-layer-upload --region "$REGION" --repository-name "$REPO" --upload-id "$up" \
        --layer-digests "$d" >/dev/null
    done
    TAG_ARGS=()
    [[ -s "$DIR/tag" ]] && TAG_ARGS=(--image-tag "$(cat "$DIR/tag")")
    aws ecr put-image --region "$REGION" --repository-name "$REPO" ${TAG_ARGS[@]+"${TAG_ARGS[@]}"} \
      --image-manifest "file://$DIR/manifest.json" \
      --image-manifest-media-type "$(cat "$DIR/mediatype")" \
      --query 'image.imageId.imageDigest' --output text | sed 's/^/==> restored /'
    ;;
  *)
    echo "usage: scripts/image.sh save|restore [dir]" >&2
    exit 2
    ;;
esac
