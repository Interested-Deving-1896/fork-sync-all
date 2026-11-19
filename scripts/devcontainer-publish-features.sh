#!/usr/bin/env bash
#
# Publishes devcontainer features from .devcontainer/features/ to GHCR as
# OCI artifacts. Requires devcontainer CLI (npm install -g @devcontainers/cli).
#
# Usage: devcontainer-publish-features.sh
#
# Required env vars:
#   REPO      — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   DRY_RUN   — true = log without pushing (default: false)
set -uo pipefail

REPO="${REPO:?REPO is required}"
DRY_RUN="${DRY_RUN:-false}"

info() { echo "[devcontainer-publish] $*" >&2; }
ok()   { echo "[devcontainer-publish][ok] $*" >&2; }
warn() { echo "[devcontainer-publish][warn] $*" >&2; }

REGISTRY="ghcr.io/${REPO,,}"
info "Publishing features to ${REGISTRY}"

for feat_dir in .devcontainer/features/*/; do
  feat_name=$(basename "$feat_dir")
  version=$(python3 -c "import json; print(json.load(open('${feat_dir}devcontainer-feature.json'))['version'])" 2>/dev/null || echo "1.0.0")

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[dry-run] would publish ${REGISTRY}/${feat_name}:${version}"
    continue
  fi

  if command -v devcontainer >/dev/null 2>&1; then
    devcontainer features publish \
      --registry "ghcr.io" \
      --namespace "${REPO,,}" \
      "$feat_dir" \
      && ok "published ${feat_name}:${version}" \
      || warn "failed to publish ${feat_name}"
  else
    warn "devcontainer CLI not available — install with: npm install -g @devcontainers/cli"
    warn "Cannot publish ${feat_name}"
  fi
done
