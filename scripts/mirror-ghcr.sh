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
DRY_RUN="${DRY_RUN:-false}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

api_get() {
  local url="$1"
  local attempt=0
  while (( attempt < 3 )); do
    local response http_code body
    response=$(curl --disable --silent --write-out "\n%{http_code}" "${AUTH[@]}" "$url")
    http_code=$(tail -1 <<< "$response")
    body=$(head -n -1 <<< "$response")
    if [[ "$http_code" == "200" ]]; then
      echo "$body"
      return 0
    elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      local reset now sleep_sec
      reset=$(curl --disable --silent --head "${AUTH[@]}" "$url" \
        | grep -i x-ratelimit-reset | awk '{print $2}' | tr -d '\r')
      now=$(date +%s)
      sleep_sec=$(( reset > now ? reset - now + 2 : 30 ))
      echo "Rate limited — sleeping ${sleep_sec}s" >&2
      sleep "$sleep_sec"
      (( attempt++ ))
    else
      echo "HTTP ${http_code} for ${url}" >&2
      return 1
    fi
  done
  return 1
}

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# Log in to GHCR
echo "$GH_TOKEN" | docker login ghcr.io -u "$(api_get "${API}/user" | jq -r '.login')" --password-stdin

SRC_LOWER=$(to_lower "$UPSTREAM_OWNER")

mirror_image() {
  local image_name="$1"   # e.g. voidlinux-ci
  local src_tag="$2"      # e.g. latest or sha

  local src="ghcr.io/${SRC_LOWER}/${image_name}:${src_tag}"

  if [[ "$DRY_RUN" == "true" ]]; then
    for dst_org in "$OSP_ORG" "$OOC_ORG"; do
      local dst_lower
      dst_lower=$(to_lower "$dst_org")
      echo "  [DRY_RUN] would push ${src} → ghcr.io/${dst_lower}/${image_name}:${src_tag}"
    done
    return 0
  fi

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
