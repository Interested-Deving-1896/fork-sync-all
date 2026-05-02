#!/usr/bin/env bash
#
# Re-tag and push GHCR images from UPSTREAM_OWNER to OSP and OOC orgs.
#
# For each image in ghcr.io/UPSTREAM_OWNER/:
#   - Pull the image
#   - Re-tag as ghcr.io/OSP_ORG_LOWER/<name>:<tag>
#   - Push to GHCR
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, OSP_ORG, OOC_ORG
# Requires: docker (available on ubuntu-latest runners)
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

# ── API helper with rate-limit retry ─────────────────────────────────────────
# GitHub REST primary limit: 5 000 req/hr per token.
# HTTP 403/429 indicates secondary (burst) rate limiting; X-RateLimit-Reset
# header gives the epoch second when the window resets.
_API_HEADER=$(mktemp)
trap 'rm -f "$_API_HEADER"' EXIT

api_get() {
  local max_retries=3 attempt=0
  while true; do
    local out http_code
    out=$(curl --disable --silent -w "
%{http_code}" \
      -D "$_API_HEADER" \
      "${AUTH[@]}" "$@" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$out" | sed '$d'; return 1; fi
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$_API_HEADER" 2>/dev/null | tr -d '' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      if [[ -n "$reset" && "$wait" -gt 0 && "$wait" -lt 3700 ]]; then
        echo "  [rate-limit] HTTP ${http_code} — sleeping ${wait}s (attempt ${attempt}/${max_retries})" >&2
        sleep "$wait"
      else
        echo "  [rate-limit] HTTP ${http_code} — backing off 60s (attempt ${attempt}/${max_retries})" >&2
        sleep 60
      fi
      continue
    fi
    echo "$out" | sed '$d'
    return 0
  done
}

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# Log in to GHCR
echo "$GH_TOKEN" | docker login ghcr.io -u "$(api_get "${API}/user" | jq -r '.login')" --password-stdin

SRC_LOWER=$(to_lower "$UPSTREAM_OWNER")

mirror_image() {
  local image_name="$1"   # e.g. voidlinux-ci
  local src_tag="$2"      # e.g. latest or sha

  local src="ghcr.io/${SRC_LOWER}/${image_name}:${src_tag}"

  echo "  Pulling: $src"
  docker pull "$src" || { echo "  FAILED to pull $src"; return 1; }

  for dst_org in "$OSP_ORG" "$OOC_ORG"; do
    local dst_lower
    dst_lower=$(to_lower "$dst_org")
    local dst="ghcr.io/${dst_lower}/${image_name}:${src_tag}"
    echo "  Pushing: $dst"
    docker tag "$src" "$dst"
    docker push "$dst" || echo "  FAILED to push $dst"
  done
}

# Get all container packages owned by UPSTREAM_OWNER
echo "Fetching GHCR packages for ${UPSTREAM_OWNER}..."
packages=$(api_get "${API}/users/${UPSTREAM_OWNER}/packages?package_type=container&per_page=100" | \
  jq -r '.[].name' 2>/dev/null)

if [[ -z "$packages" ]]; then
  echo "No GHCR packages found for ${UPSTREAM_OWNER} — nothing to mirror."
  exit 0
fi

echo "Found packages: $(echo "$packages" | tr '\n' ' ')"
echo ""

while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  echo "=== Mirroring: $pkg ==="

  # Get all versions/tags for this package
  versions=$(api_get \
    "${API}/users/${UPSTREAM_OWNER}/packages/container/${pkg}/versions?per_page=100" | \
    jq -r '.[] | .metadata.container.tags[]?' 2>/dev/null | sort -u)

  if [[ -z "$versions" ]]; then
    # Fall back to just mirroring :latest
    mirror_image "$pkg" "latest"
  else
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      mirror_image "$pkg" "$tag"
    done <<< "$versions"
  fi
  echo ""
done <<< "$packages"

echo "GHCR mirror complete."
