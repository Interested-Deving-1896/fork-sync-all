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
# REPO_FILTER: substring — only process repos whose name contains this string
REPO_FILTER="${REPO_FILTER:-}"
# RELEASE_TAG: exact tag — only mirror this specific release (blank = all)
RELEASE_TAG="${RELEASE_TAG:-}"
# FORCE: re-mirror releases that already exist in the mirror org
FORCE="${FORCE:-false}"

[[ -n "$REPO_FILTER"   ]] && echo "Repo filter:   '${REPO_FILTER}'"
[[ -n "$RELEASE_TAG"   ]] && echo "Release tag:   '${RELEASE_TAG}'"
[[ "$FORCE"   == "true" ]] && echo "Force mode:    existing releases will be re-mirrored"
[[ "$DRY_RUN" == "true" ]] && echo "Dry run:       no releases will be created"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
EXCLUDED_REPOS=("fork-sync-all" "org-mirror")

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

  # Get upstream releases (filter by tag if RELEASE_TAG is set)
  local releases_url="${API}/repos/${src_org}/${src_repo}/releases?per_page=100"
  local upstream_releases
  upstream_releases=$(api_get "$releases_url")
  local count
  count=$(echo "$upstream_releases" | jq 'length' 2>/dev/null || echo 0)
  [[ "$count" == "0" || "$count" == "null" ]] && return

  # If a specific tag is requested, filter to just that release
  if [[ -n "$RELEASE_TAG" ]]; then
    upstream_releases=$(echo "$upstream_releases" | jq --arg t "$RELEASE_TAG" '[.[] | select(.tag_name == $t)]')
    count=$(echo "$upstream_releases" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" ]] && { echo "  No release with tag '${RELEASE_TAG}' found in ${src_org}/${src_repo}"; return; }
  fi

  echo "  ${src_org}/${src_repo} -> ${dst_org}/${src_repo}: $count upstream release(s)"

  # Get existing tags in mirror to avoid duplicates (skipped when FORCE=true)
  local existing_tags=""
  if [[ "$FORCE" != "true" ]]; then
    existing_tags=$(api_get "${API}/repos/${dst_org}/${src_repo}/releases?per_page=100" | \
      jq -r '.[].tag_name' 2>/dev/null || echo "")
  fi

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

    # Skip if already mirrored (unless FORCE=true)
    if [[ "$FORCE" != "true" ]] && echo "$existing_tags" | grep -qxF "$tag"; then
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

    # Apply repo name substring filter
    if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
      continue
    fi

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
