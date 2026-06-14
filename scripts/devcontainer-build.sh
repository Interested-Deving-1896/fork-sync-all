#!/usr/bin/env bash
#
# Builds and pushes the devcontainer image to GHCR.
# Falls back to plain docker build if devcontainer CLI is unavailable.
#
# Required env vars:
#   REPO     — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   SHA      — git commit SHA
#   DRY_RUN  — true = log without pushing (default: false)
set -uo pipefail

REPO="${REPO:?REPO is required}"
SHA="${SHA:?SHA is required}"
DRY_RUN="${DRY_RUN:-false}"

info() { echo "[devcontainer-build] $*" >&2; }
ok()   { echo "[devcontainer-build][ok] $*" >&2; }
warn() { echo "[devcontainer-build][warn] $*" >&2; }

IMAGE="ghcr.io/${REPO,,}/devcontainer"
TAG="${SHA:0:7}"

info "Image: ${IMAGE}:${TAG}"

if [[ "$DRY_RUN" == "true" ]]; then
  info "[dry-run] would build and push ${IMAGE}:${TAG}"
  exit 0
fi

BASE_IMAGE=$(python3 scripts/devcontainer-base-image.py)
info "Base image: ${BASE_IMAGE}"

if command -v devcontainer >/dev/null 2>&1; then
  info "Using devcontainer CLI..."
  devcontainer build \
    --workspace-folder . \
    --image-name "${IMAGE}:${TAG}" \
    --push
else
  info "devcontainer CLI not found — using plain docker build..."

  # Write Dockerfile to a temp file to avoid heredoc in YAML
  TMPFILE=$(mktemp /tmp/Dockerfile.XXXXXX)
  cat > "$TMPFILE" << 'DOCKERFILE_CONTENT'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY . /workspace
WORKDIR /workspace
RUN pip install --quiet 'headroom-ai[proxy,mcp]==0.25.0' 2>/dev/null || true
DOCKERFILE_CONTENT

  docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --label "org.opencontainers.image.source=https://github.com/${REPO}" \
    --label "org.opencontainers.image.revision=${SHA}" \
    -t "${IMAGE}:${TAG}" \
    -t "${IMAGE}:latest" \
    -f "$TMPFILE" .

  rm -f "$TMPFILE"
  docker push "${IMAGE}:${TAG}"
  docker push "${IMAGE}:latest"
fi

ok "Built and pushed ${IMAGE}:${TAG}"
echo "image=${IMAGE}:${TAG}" >> "${GITHUB_OUTPUT:-/dev/null}"
