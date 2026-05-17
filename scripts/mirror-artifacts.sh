#!/usr/bin/env bash
#
# Orchestrate all artifact mirroring from UPSTREAM_OWNER to OSP and OOC.
# Called by the mirror-artifacts workflow on release events and hourly.
#
# For each repo in OSP/OOC:
#   - GitHub Releases + assets  (always)
#   - GHCR images               (if repo has build-ci-images.yml)
#   - PyPI packages             (if repo has publish.yml targeting PyPI)
#   - Flatpak bundles           (if release has .flatpak assets)
#   - RPM packages              (if release has .rpm assets)
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, OSP_ORG, OOC_ORG
# Optional: UPSTREAM_REPO, RELEASE_TAG (if triggered by a specific release)
#
set -uo pipefail

: "${GH_TOKEN:?required}"
: "${UPSTREAM_OWNER:?required}"
: "${OSP_ORG:?required}"
: "${OOC_ORG:?required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
FORCE="${FORCE:-false}"

[[ "$DRY_RUN" == "true" ]] && echo "Dry run — no writes will occur."
[[ "$FORCE"   == "true" ]] && echo "Force mode — existing releases will be re-mirrored."
[[ -n "$REPO_FILTER"    ]] && echo "Repo filter: '${REPO_FILTER}'"
[[ -n "$RELEASE_TAG"    ]] && echo "Release tag: '${RELEASE_TAG}'"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
      echo "$body"; return 0
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
      echo "HTTP ${http_code} for ${url}" >&2; return 1
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

has_workflow() {
  local org="$1" repo="$2" wf="$3"
  local result
  result=$(api_get "${API}/repos/${org}/${repo}/contents/.github/workflows/${wf}")
  echo "$result" | jq -e '.sha' > /dev/null 2>&1
}

# Mirror Flatpak/RPM packages for releases of a single repo to a single org.
# GitHub Releases themselves are handled by mirror-releases.sh (called in main).
mirror_packages_for_repo() {
  local src_repo="$1" dst_org="$2"

  # Fetch releases to check for Flatpak/RPM assets
  local releases
  if [[ -n "$RELEASE_TAG" ]]; then
    local r
    r=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${src_repo}/releases/tags/${RELEASE_TAG}" 2>/dev/null || true)
    releases="[$r]"
  else
    releases=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${src_repo}/releases?per_page=100" 2>/dev/null || true)
  fi

  local count
  count=$(echo "$releases" | jq 'length' 2>/dev/null || echo 0)
  [[ "$count" == "0" || "$count" == "null" ]] && return

  while IFS= read -r release; do
    local tag draft
    tag=$(echo "$release" | jq -r '.tag_name')
    draft=$(echo "$release" | jq -r '.draft')
    [[ "$draft" == "true" ]] && continue

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    DRY  would mirror packages for ${dst_org}/${src_repo}:${tag}"
      continue
    fi

    # Mirror Flatpak if .flatpak asset present
    if echo "$release" | jq -e '.assets[] | select(.name | endswith(".flatpak"))' > /dev/null 2>&1; then
      echo "    [flatpak] ${dst_org}/${src_repo}: $tag"
      UPSTREAM_REPO="$src_repo" TARGET_ORG="$dst_org" RELEASE_TAG="$tag" \
        bash "${SCRIPT_DIR}/mirror-flatpak.sh" || echo "    flatpak mirror failed (non-fatal)"
    fi

    # Mirror RPM if .rpm asset present
    if echo "$release" | jq -e '.assets[] | select(.name | endswith(".rpm"))' > /dev/null 2>&1; then
      echo "    [rpm] ${dst_org}/${src_repo}: $tag"
      UPSTREAM_REPO="$src_repo" TARGET_ORG="$dst_org" RELEASE_TAG="$tag" \
        bash "${SCRIPT_DIR}/mirror-rpm.sh" || echo "    rpm mirror failed (non-fatal)"
    fi
  done < <(echo "$releases" | jq -c '.[]')
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
remaining=$(api_get "${API}/rate_limit" | jq -r '.resources.core.remaining // empty')
[[ -z "$remaining" ]] && { echo "ERROR: GH_TOKEN invalid."; exit 1; }
echo "Token valid. Core API requests remaining: $remaining"
echo ""

# GHCR mirror runs once (not per-repo)
echo "========================================"
echo "Mirroring GHCR images"
echo "========================================"
DRY_RUN="$DRY_RUN" bash "${SCRIPT_DIR}/mirror-ghcr.sh" || echo "GHCR mirror failed (non-fatal)"
echo ""

# Per-repo release + package mirroring.
#
# IMPORTANT: mirror-releases.sh already iterates over BOTH OSP_ORG and OOC_ORG
# internally (it has its own `for org in "$OSP_ORG" "$OOC_ORG"` loop).
# We must NOT call it once per org here — that would mirror every release twice
# to each org (4 total attempts per repo).  Instead we call it once per repo
# and let it handle all target orgs itself.
echo "========================================"
echo "Mirroring releases (all orgs)"
echo "========================================"

# Build the repo list from OSP (canonical mirror org); OOC is handled by mirror-releases.sh
if [[ -n "$UPSTREAM_REPO" ]]; then
  repos="$UPSTREAM_REPO"
else
  repos=$(get_org_repos "$OSP_ORG")
fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  is_excluded "$repo" && continue

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  upstream_name=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}" | jq -r '.name // empty')
  [[ -z "$upstream_name" ]] && continue

  echo "  --- ${repo} ---"

  # Delegate GitHub Releases mirroring to mirror-releases.sh (handles both orgs internally)
  REPO_FILTER="$repo" RELEASE_TAG="$RELEASE_TAG" DRY_RUN="$DRY_RUN" FORCE="$FORCE" \
    bash "${SCRIPT_DIR}/mirror-releases.sh" || echo "  releases mirror failed (non-fatal)"

  # Mirror Flatpak/RPM packages to each org (not handled by mirror-releases.sh)
  for org in "$OSP_ORG" "$OOC_ORG"; do
    mirror_packages_for_repo "$repo" "$org"
  done

  echo ""
done <<< "$repos"

echo "========================================"
echo "Artifact mirror complete."
echo "========================================"
