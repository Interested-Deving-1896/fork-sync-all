#!/usr/bin/env bash
#
# Mirrors configured OSP-bound repos from Interested-Deving-1896 to
# OpenOS-Project-OSP and OpenOS-Project-Ecosystem-OOC using bare clone +
# push --mirror.
#
# Repository scope comes from config/gitlab-subgroups.yml. Source metadata is
# fetched with exact repository(owner:, name:) GraphQL lookups, which work for
# both user and organization owners without enumerating every owner repository.
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
#   OSP_REPOS_CONFIG — OSP-bound repo registry (default: config/gitlab-subgroups.yml)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

UPSTREAM_OWNER="${UPSTREAM_OWNER:-Interested-Deving-1896}"
OSP_ORG="${OSP_ORG:-OpenOS-Project-OSP}"
OOC_ORG="${OOC_ORG:-OpenOS-Project-Ecosystem-OOC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSP_REPOS_CONFIG="${OSP_REPOS_CONFIG:-${SCRIPT_DIR}/../config/gitlab-subgroups.yml}"
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

# ── Budget guard ─────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/includes/budget.sh"
budget_init

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

load_configured_repos() {
  local config_path="$1"
  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: OSP repo registry not found: ${config_path}" >&2
    return 1
  fi

  python3 - "$config_path" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle) or {}

seen = set()
for subgroup in (config.get("subgroups", {}) or {}).values():
    for repo in (subgroup.get("repos") or []):
        if isinstance(repo, str) and repo and repo not in seen:
            seen.add(repo)
            print(repo)
PYEOF
}

parse_repository_aliases() {
  python3 -c '
import json, sys

payload = json.load(sys.stdin)
if payload.get("errors"):
    print("; ".join(error.get("message", "GraphQL error") for error in payload["errors"]), file=sys.stderr)
    raise SystemExit(1)
data = payload.get("data")
if not isinstance(data, dict):
    print("GraphQL response did not contain repository data", file=sys.stderr)
    raise SystemExit(1)
for alias, repository in data.items():
    if repository and repository.get("name"):
        print("{}\t{}\t{}".format(
            alias[1:], repository["name"], repository.get("diskUsage") or 0
        ))
'
}

# Populate source existence and size caches in bounded GraphQL batches. Exact
# repository lookups are owner-type agnostic and avoid enumerating a user with
# thousands of unrelated repositories.
declare -A _SOURCE_EXISTS=()
declare -A _repo_sizes=()
prefetch_source_metadata() {
  local owner="$1"; shift
  local repos=("$@")
  local batch_size=50 start

  for (( start=0; start<${#repos[@]}; start+=batch_size )); do
    local batch=("${repos[@]:start:batch_size}")
    local aliases="" i=0 name
    for name in "${batch[@]}"; do
      aliases+="r${i}: repository(owner: \\\"${owner}\\\", name: \\\"${name}\\\") { name diskUsage } "
      (( i++ )) || true
    done

    local result parsed
    if ! result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/graphql" \
      -d "{\"query\":\"{ ${aliases} }\"}"); then
      echo "ERROR: failed to query source repository metadata for ${owner}" >&2
      return 1
    fi
    if ! parsed=$(parse_repository_aliases <<< "$result"); then
      echo "ERROR: invalid source repository response for ${owner}" >&2
      return 1
    fi

    for name in "${batch[@]}"; do
      _SOURCE_EXISTS["$name"]="false"
    done
    while IFS=$'\t' read -r index _actual_name size; do
      [[ -z "$index" ]] && continue
      name="${batch[$index]}"
      _SOURCE_EXISTS["$name"]="true"
      _repo_sizes["$name"]="${size:-0}"
    done <<< "$parsed"
  done
}

# Prefetch repo existence for destination orgs in bounded GraphQL batches.
# Populates _DST_EXISTS["org/repo"] = "true"|"false".
declare -A _DST_EXISTS=()
prefetch_dst_existence() {
  local org="$1"; shift
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && return 0
  local batch_size=50 start

  for (( start=0; start<${#repos[@]}; start+=batch_size )); do
    local batch=("${repos[@]:start:batch_size}")
    local aliases="" i=0 name
    for name in "${batch[@]}"; do
      aliases+="r${i}: repository(owner: \\\"${org}\\\", name: \\\"${name}\\\") { name } "
      (( i++ )) || true
    done

    local result parsed
    if ! result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/graphql" \
      -d "{\"query\":\"{ ${aliases} }\"}"); then
      echo "ERROR: failed to query destination repositories for ${org}" >&2
      return 1
    fi
    if ! parsed=$(parse_repository_aliases <<< "$result"); then
      echo "ERROR: invalid destination repository response for ${org}" >&2
      return 1
    fi

    for name in "${batch[@]}"; do
      _DST_EXISTS["${org}/${name}"]="false"
    done
    while IFS=$'\t' read -r index _actual_name _size; do
      [[ -z "$index" ]] && continue
      name="${batch[$index]}"
      _DST_EXISTS["${org}/${name}"]="true"
    done <<< "$parsed"
  done
}

ensure_repo_exists() {
  local org="$1" repo="$2" src_org="$3"
  # Use prefetch cache — only fall back to REST on cache miss
  local exists="${_DST_EXISTS["${org}/${repo}"]:-}"
  if [[ "$exists" == "true" ]]; then
    return 0
  fi
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
    _DST_EXISTS["${org}/${repo}"]="true"
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

echo "Loading OSP-bound repos from ${OSP_REPOS_CONFIG}..."
configured_output=$(load_configured_repos "$OSP_REPOS_CONFIG") || exit 1
mapfile -t configured_repos <<< "$configured_output"

# Narrow the configured scope before any API calls. This keeps filtered runs
# cheap and prevents accidental enumeration of every repository owned by a user.
candidates=()
for repo in "${configured_repos[@]}"; do
  [[ -z "$repo" ]] && continue
  is_excluded "$repo" && continue
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
  candidates+=("$repo")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "ERROR: no configured OSP-bound repositories matched the requested filter" >&2
  exit 1
fi

echo "Checking ${#candidates[@]} configured repos in ${UPSTREAM_OWNER}..."
prefetch_source_metadata "$UPSTREAM_OWNER" "${candidates[@]}" || exit 1

repos=()
for repo in "${candidates[@]}"; do
  if [[ "${_SOURCE_EXISTS[$repo]:-false}" == "true" ]]; then
    repos+=("$repo")
  else
    echo "WARN: configured source repository not found: ${UPSTREAM_OWNER}/${repo}" >&2
  fi
done

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "ERROR: none of the configured OSP-bound repositories exist under ${UPSTREAM_OWNER}" >&2
  exit 1
fi

# Pre-fetch destination existence only for confirmed source repositories.
for _dst in "$OSP_ORG" "$OOC_ORG"; do
  [[ "$_dst" == "SKIP" ]] && continue
  prefetch_dst_existence "$_dst" "${repos[@]}" || exit 1
done

echo "Repos to mirror: ${#repos[@]}"
[[ "$DRY_RUN" == "true" ]] && echo "(dry run)"

synced=0
failed=0
oversized=0

for repo in "${repos[@]}"; do
  budget_check "$repo" || break
  # Skip repos that exceed the size threshold — bare clone + push of multi-GB
  # repos exceeds the job timeout. These are typically upstream forks.
  # Size comes from the batched source GraphQL fetch above.
  repo_size="${_repo_sizes[$repo]:-0}"
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
budget_report
[[ "$failed" -eq 0 ]]
