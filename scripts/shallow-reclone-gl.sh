#!/usr/bin/env bash
#
# Shallow-reclones large GitLab mirror projects to reduce storage usage.
#
# For each target project:
#   1. Fetches the remote URL and default branch from the GitLab API.
#   2. Clones at the specified depth into a temp directory.
#   3. Force-pushes the shallow history back to GitLab, replacing the full
#      history. This permanently discards history beyond the depth — only
#      do this on mirror repos where history is not the source of truth.
#
# Requires:
#   GITLAB_TOKEN  — PAT with api + write_repository on the target projects
#
# Usage:
#   DEPTH=1 bash scripts/shallow-reclone-gl.sh
#
set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

DEPTH="${DEPTH:-1}"
DRY_RUN="${DRY_RUN:-false}"
GL_API="https://gitlab.com/api/v4"
GL_AUTH=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

# Project IDs and names for large repos to shallow-reclone.
# Ordered largest-first. openfyde/chromium is intentionally absent —
# it should be deleted outright, not shallow-recloned (51+ GiB).
TARGETS=(
  "81771677:openfyde/kernel-rockchip-6"
  "81770634:fydeos-for-you-overlays/kernel-rockchip"
  "81771700:openfyde/chromiumos-overlay"
  "81834467:brave-software/brave-ios"
  "81834684:brave-software/chromium-releases"
  "81774947:chromium-browser-deving/vanadium"
  "81771853:openfyde/foundation-rk3588"
  "81770361:fydeos-for-you-overlays/kernel-rpi"
  "81770372:fydeos-for-you-overlays/kernel-surface"
  "81774450:chromiumos-deving/chromiumos-platform2"
  "81771833:openfyde/foundation-realtek"
)

ok=0
failed=0

for entry in "${TARGETS[@]}"; do
  project_id="${entry%%:*}"
  display_name="${entry##*:}"

  echo "── ${display_name} (id=${project_id}) ──"

  # Fetch project details
  project_json=$(curl --disable --silent "${GL_AUTH[@]}" \
    "${GL_API}/projects/${project_id}" 2>/dev/null)

  remote_url=$(echo "$project_json" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('http_url_to_repo',''))" 2>/dev/null)
  default_branch=$(echo "$project_json" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('default_branch','main'))" 2>/dev/null)

  if [[ -z "$remote_url" ]]; then
    echo "  SKIP: could not fetch project details"
    (( failed++ )) || true
    continue
  fi

  # Inject token into URL for push auth
  auth_url="${remote_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  echo "  remote: ${remote_url}"
  echo "  branch: ${default_branch}  depth: ${DEPTH}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would shallow-reclone at depth ${DEPTH}"
    (( ok++ )) || true
    continue
  fi

  # Clone shallow into temp dir
  tmp=$(mktemp -d)
  if ! git clone --depth "${DEPTH}" --branch "${default_branch}" \
      --single-branch "${auth_url}" "${tmp}/repo" 2>/dev/null; then
    echo "  FAILED: clone failed" >&2
    rm -rf "$tmp"
    (( failed++ )) || true
    continue
  fi

  # Force-push the shallow history back
  if ! git -C "${tmp}/repo" push --force "${auth_url}" \
      "${default_branch}:${default_branch}" 2>/dev/null; then
    echo "  FAILED: push failed" >&2
    rm -rf "$tmp"
    (( failed++ )) || true
    continue
  fi

  # Run git gc on the remote to reclaim storage immediately
  curl --disable --silent -o /dev/null \
    -X POST "${GL_AUTH[@]}" \
    "${GL_API}/projects/${project_id}/housekeeping" 2>/dev/null || true

  rm -rf "$tmp"
  echo "  done"
  (( ok++ )) || true
done

echo ""
echo "shallow-reclone-gl: done — ok=${ok} failed=${failed}"
[[ "$failed" -gt 0 ]] && exit 1
exit 0
