#!/usr/bin/env bash
#
# Mirror GitHub Releases from UPSTREAM_OWNER to OSP and OOC mirror orgs.
#
# For each repo in OSP/OOC that has a counterpart in UPSTREAM_OWNER:
#   1. Fetch all releases from upstream
#   2. For each release not yet present in the mirror org, create it and
#      download + re-upload all release assets
#   3. Release body has a "Mirrored from" footer added
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, OSP_ORG, OOC_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"
DRY_RUN="${DRY_RUN:-false}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
EXCLUDED_REPOS=("fork-sync-all" "org-mirror")

api_get() { curl --disable --silent "${AUTH[@]}" "$@"; }

is_excluded() {
  local r="$1"
  for ex in "${EXCLUDED_REPOS[@]}"; do [[ "$r" == "$ex" ]] && return 0; done
  return 1
}

get_org_repos() {
  local org="$1" page=1
  while true; do
    local result count
    result=$(api_get "${API}/orgs/${org}/repos?type=all&per_page=100&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
}

mirror_releases() {
  local src_org="$1" src_repo="$2" dst_org="$3"
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  # Get upstream releases
  local upstream_releases
  upstream_releases=$(api_get "${API}/repos/${src_org}/${src_repo}/releases?per_page=100")
  local count
  count=$(echo "$upstream_releases" | jq 'length' 2>/dev/null || echo 0)
  [[ "$count" == "0" || "$count" == "null" ]] && return

  echo "  ${src_org}/${src_repo} -> ${dst_org}/${src_repo}: $count upstream release(s)"

  # Get existing tags in mirror to avoid duplicates
  local existing_tags
  existing_tags=$(api_get "${API}/repos/${dst_org}/${src_repo}/releases?per_page=100" | \
    jq -r '.[].tag_name' 2>/dev/null || echo "")

  local mirrored=0

  while IFS= read -r release; do
    local tag name body prerelease draft
    tag=$(echo "$release" | jq -r '.tag_name')
    name=$(echo "$release" | jq -r '.name // .tag_name')
    body=$(echo "$release" | jq -r '.body // ""')
    prerelease=$(echo "$release" | jq -r '.prerelease')
    draft=$(echo "$release" | jq -r '.draft')

    # Skip drafts
    [[ "$draft" == "true" ]] && continue

    # Skip if already mirrored
    if echo "$existing_tags" | grep -qxF "$tag"; then
      continue
    fi

    echo "    Mirroring release: $tag ($name)"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "    [dry-run] Would create release ${tag} in ${dst_org}/${src_repo}"
      (( mirrored++ )) || true
      continue
    fi

    # Append mirror attribution to body
    local mirror_body
    mirror_body="${body}

---
*Mirrored from [${src_org}/${src_repo}](https://github.com/${src_org}/${src_repo}/releases/tag/${tag})*"

    # Create the release in the mirror org
    local create_payload
    create_payload=$(jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg body "$mirror_body" \
      --argjson prerelease "$prerelease" \
      '{tag_name: $tag, name: $name, body: $body, prerelease: $prerelease, draft: false}')

    local new_release
    new_release=$(curl --disable --silent -X POST \
      "${AUTH[@]}" \
      -H "Content-Type: application/json" \
      "${API}/repos/${dst_org}/${src_repo}/releases" \
      -d "$create_payload")

    local new_release_id upload_url
    new_release_id=$(echo "$new_release" | jq -r '.id // empty')
    upload_url=$(echo "$new_release" | jq -r '.upload_url // empty' | sed 's/{?name,label}//')

    if [[ -z "$new_release_id" ]]; then
      echo "    FAILED to create release $tag: $(echo "$new_release" | jq -r '.message // "unknown error"')"
      continue
    fi

    # Download and re-upload each asset
    local assets
    assets=$(echo "$release" | jq -r '.assets[] | "\(.id) \(.name) \(.content_type) \(.browser_download_url)"')

    while IFS= read -r asset_line; do
      [[ -z "$asset_line" ]] && continue
      local asset_name content_type download_url
      asset_name=$(echo "$asset_line" | awk '{print $2}')
      content_type=$(echo "$asset_line" | awk '{print $3}')
      download_url=$(echo "$asset_line" | awk '{print $4}')

      local asset_file="${tmpdir}/${asset_name}"
      echo "      Downloading: $asset_name"
      curl --disable --silent -L \
        -H "Authorization: token ${GH_TOKEN}" \
        -o "$asset_file" \
        "$download_url"

      echo "      Uploading: $asset_name"
      curl --disable --silent -o /dev/null -w "      Upload HTTP: %{http_code}\n" \
        -X POST \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Content-Type: ${content_type}" \
        "${upload_url}?name=${asset_name}" \
        --data-binary "@${asset_file}"

      rm -f "$asset_file"
    done <<< "$assets"

    (( mirrored++ )) || true

  done < <(echo "$upstream_releases" | jq -c '.[]')

  echo "    done: $mirrored new release(s) mirrored"
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
remaining=$(api_get "${API}/rate_limit" | jq -r '.resources.core.remaining // empty')
[[ -z "$remaining" ]] && { echo "ERROR: GH_TOKEN invalid."; exit 1; }
echo "Token valid. Core API requests remaining: $remaining"
echo ""

total=0

for org in "$OSP_ORG" "$OOC_ORG"; do
  echo "========================================"
  echo "Mirroring releases to ${org}"
  echo "========================================"

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    is_excluded "$repo" && continue

    # Only process repos that exist on upstream
    upstream_name=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}" | jq -r '.name // empty')
    [[ -z "$upstream_name" ]] && continue

    mirror_releases "$UPSTREAM_OWNER" "$repo" "$org"
    (( total++ )) || true
    echo ""
  done < <(get_org_repos "$org")
done

echo "========================================"
echo "  Release mirror complete. Repos: $total"
echo "========================================"
