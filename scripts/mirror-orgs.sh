#!/usr/bin/env bash
#
# Mirrors all repos from Interested-Deving-1896 to OpenOS-Project-OSP and
# OpenOS-Project-Ecosystem-OOC using bare clone + push --mirror.
#
# This is the replacement for the absorbed org-mirror repo. It uses dynamic
# API discovery (no hardcoded repo list) and supports DRY_RUN for safe testing.
#
# Required env vars:
#   GH_TOKEN  — PAT with repo scope on all three orgs
#
# Optional env vars:
#   UPSTREAM_OWNER  — source org (default: Interested-Deving-1896)
#   OSP_ORG         — first mirror org (default: OpenOS-Project-OSP)
#   OOC_ORG         — second mirror org (default: OpenOS-Project-Ecosystem-OOC)
#   REPO_FILTER     — substring filter on repo name (default: blank = all)
#   DRY_RUN         — if "true", print actions without pushing (default: false)
#   EXCLUDED_REPOS  — space-separated repo names to skip

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

UPSTREAM_OWNER="${UPSTREAM_OWNER:-Interested-Deving-1896}"
OSP_ORG="${OSP_ORG:-OpenOS-Project-OSP}"
OOC_ORG="${OOC_ORG:-OpenOS-Project-Ecosystem-OOC}"
# 'SKIP' is the sentinel passed by mirror-orgs-full.yml when osp-only or
# ooc-only is selected. An empty string can't be used because GHA ternary
# expressions treat '' as falsy and always evaluate to the else branch.
# The loop below skips any org set to SKIP.
REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
EXCLUDED_REPOS="${EXCLUDED_REPOS:-org-mirror}"

# Repos larger than this threshold (in KB) are skipped — bare clone + push
# of multi-GB repos exceeds the job timeout and provides no practical value
# since these are upstream forks, not actively developed OSP content.
# Default: 500 MB. Override via MAX_REPO_SIZE_MB or MAX_REPO_SIZE_KB env var.
# MAX_REPO_SIZE_MB is preferred (avoids fromJSON arithmetic in workflow YAML).
if [[ -n "${MAX_REPO_SIZE_MB:-}" ]]; then
  MAX_REPO_SIZE_KB=$(( MAX_REPO_SIZE_MB * 1024 ))
else
  MAX_REPO_SIZE_KB="${MAX_REPO_SIZE_KB:-512000}"
fi

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

api_get() {
  local url="$1"; shift
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
      local reset
      reset=$(curl --disable --silent --head "${AUTH[@]}" "$url" \
        | grep -i x-ratelimit-reset | awk '{print $2}' | tr -d '\r')
      local now; now=$(date +%s)
      local sleep_sec=$(( reset > now ? reset - now + 2 : 30 ))
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
  local repo="$1"
  for ex in $EXCLUDED_REPOS; do
    [[ "$repo" == "$ex" ]] && return 0
  done
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

ensure_repo_exists() {
  local org="$1" repo="$2" src_org="$3"
  local check
  check=$(curl --disable --silent --write-out "%{http_code}" --output /dev/null \
    "${AUTH[@]}" "${API}/repos/${org}/${repo}")
  if [[ "$check" == "404" ]]; then
    echo "  Creating ${org}/${repo}"
    if [[ "$DRY_RUN" != "true" ]]; then
      local desc
      desc=$(api_get "${API}/repos/${src_org}/${repo}" | jq -r '.description // ""')
      local create_response create_code
      create_response=$(curl --disable --silent --write-out "\n%{http_code}" -X POST "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        "${API}/orgs/${org}/repos" \
        -d "$(jq -n --arg name "$repo" --arg desc "$desc" \
          '{"name":$name,"description":$desc,"private":false,"auto_init":false}')")
      create_code=$(tail -1 <<< "$create_response")
      if [[ "$create_code" != "201" ]]; then
        echo "  ERROR: failed to create ${org}/${repo} (HTTP ${create_code})" >&2
        echo "  $(head -n -1 <<< "$create_response" | jq -r '.message // empty' 2>/dev/null)" >&2
        return 1
      fi
    fi
  fi
}

mirror_repo() {
  local src_org="$1" repo="$2" dst_org="$3"
  local src_url="https://x-access-token:${GH_TOKEN}@github.com/${src_org}/${repo}.git"
  local dst_url="https://x-access-token:${GH_TOKEN}@github.com/${dst_org}/${repo}.git"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  DRY  push --mirror ${src_org}/${repo} → ${dst_org}/${repo}"
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  echo "  Cloning ${src_org}/${repo} (bare)..."
  if ! git clone --bare --quiet "$src_url" "$tmpdir/repo.git" 2>&1; then
    echo "  FAIL clone ${src_org}/${repo}" >&2
    return 1
  fi

  echo "  Pushing → ${dst_org}/${repo}..."
  if ! git -C "$tmpdir/repo.git" push --mirror --quiet "$dst_url" 2>&1; then
    echo "  FAIL push ${dst_org}/${repo}" >&2
    return 1
  fi

  echo "  OK   ${src_org}/${repo} → ${dst_org}/${repo}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "Discovering repos in ${UPSTREAM_OWNER}..."
mapfile -t all_repos <<< "$(get_org_repos "$UPSTREAM_OWNER")"

# Apply filter and exclusions
repos=()
for repo in "${all_repos[@]}"; do
  [[ -z "$repo" ]] && continue
  is_excluded "$repo" && continue
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
  repos+=("$repo")
done

echo "Repos to mirror: ${#repos[@]}"
[[ "$DRY_RUN" == "true" ]] && echo "(dry run)"

synced=0
failed=0
oversized=0

for repo in "${repos[@]}"; do
  # Skip repos that exceed the size threshold — bare clone + push of multi-GB
  # repos exceeds the job timeout. These are typically upstream forks.
  repo_size=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${UPSTREAM_OWNER}/${repo}" \
    | jq -r '.size // 0' 2>/dev/null || echo 0)
  if [[ "$repo_size" -gt "$MAX_REPO_SIZE_KB" ]]; then
    size_mb=$(( repo_size / 1024 ))
    echo "SKIP (oversized ${size_mb}MB > $(( MAX_REPO_SIZE_KB / 1024 ))MB limit): ${repo}"
    (( oversized++ ))
    continue
  fi

  echo "Processing: ${repo}"
  for dst_org in "$OSP_ORG" "$OOC_ORG"; do
    [[ "$dst_org" == "SKIP" ]] && continue
    ensure_repo_exists "$dst_org" "$repo" "$UPSTREAM_OWNER"
    if mirror_repo "$UPSTREAM_OWNER" "$repo" "$dst_org"; then
      (( synced++ ))
    else
      (( failed++ ))
    fi
  done
done

echo ""
echo "Done: ${synced} mirrors pushed, ${oversized} oversized skipped, ${failed} failed"
[[ "$failed" -eq 0 ]]
