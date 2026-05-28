#!/usr/bin/env bash
# scripts/sync-registry-sources.sh — sync a repo's feature branch and its declared
# upstream dependencies.
#
# This is the agnostic generalisation of sync-pieroproietti-forks.sh.
# Where that script syncs all GitHub forks of a single upstream owner,
# this script syncs:
#
#   1. A named "core" fork (e.g. a penguins-eggs all-features branch) against
#      its upstream (e.g. pieroproietti/penguins-eggs master).
#
#   2. Every project declared in a registry file — handling both:
#        a. GitHub forks  — repos GitHub knows are forks; synced via
#                           merge-upstream (same as sync-pieroproietti-forks.sh)
#        b. Explicit deps — repos that are NOT GitHub forks but declare an
#                           upstream in the registry (e.g. imported repos,
#                           repos created from scratch that track an upstream).
#                           Synced via merge-upstream if the upstream is on
#                           GitHub, or reported as needing manual sync otherwise.
#
# Registry file format (JSON, same schema as all-features-registry.json):
#
#   {
#     "upstream_core": {                     ← optional; the "main" fork
#       "repo":          "owner/repo",       ← fork to sync
#       "branch":        "master",           ← upstream branch to pull from
#       "target_branch": "all-features",     ← branch in GITHUB_OWNER fork
#       "sync_strategy": "merge-upstream"
#     },
#     "projects": [                          ← list of dependency projects
#       {
#         "name":            "my-project",
#         "repo":            "GITHUB_OWNER/my-project",
#         "default_branch":  "main",
#         "upstream":        "upstream-owner/upstream-repo",  ← null = no upstream
#         "upstream_branch": "main",
#         "sync_strategy":   "merge-upstream"  ← or "none"
#       },
#       ...
#     ]
#   }
#
# The registry file can be:
#   - A local path (REGISTRY_FILE=/path/to/registry.json)
#   - Fetched from a remote repo at runtime:
#       REGISTRY_REPO=owner/repo
#       REGISTRY_BRANCH=all-features
#       REGISTRY_PATH=config/all-features-registry.json
#
# Required env vars:
#   GH_TOKEN       — PAT with repo + pull_requests scopes
#   GITHUB_OWNER   — org that owns the fork repos (e.g. Interested-Deving-1896)
#
# Registry source (one of):
#   REGISTRY_FILE    — local path to registry JSON
#   REGISTRY_REPO    — remote repo (owner/repo) to fetch registry from
#   REGISTRY_BRANCH  — branch in REGISTRY_REPO (default: main)
#   REGISTRY_PATH    — path within REGISTRY_REPO (default: config/registry.json)
#
# Optional env vars:
#   DRY_RUN          — true | false (default: false)
#   REPO_FILTER      — only process projects whose name contains this string
#   SKIP_CORE        — true | false — skip the upstream_core sync (default: false)
#   SKIP_PROJECTS    — true | false — skip the projects sync (default: false)
#   BUDGET_MINUTES   — time budget in minutes before stopping early (default: 50)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
SKIP_CORE="${SKIP_CORE:-false}"
SKIP_PROJECTS="${SKIP_PROJECTS:-false}"
BUDGET_MINUTES="${BUDGET_MINUTES:-50}"
BUDGET_SECONDS=$(( BUDGET_MINUTES * 60 ))

REGISTRY_FILE="${REGISTRY_FILE:-}"
REGISTRY_REPO="${REGISTRY_REPO:-}"
REGISTRY_BRANCH="${REGISTRY_BRANCH:-main}"
REGISTRY_PATH="${REGISTRY_PATH:-config/registry.json}"

API="https://api.github.com"
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

START_TIME=$(date +%s)

synced=0
failed=0
skipped=0

info()  { echo "[sync-registry-sources] $*"; }
warn()  { echo "[sync-registry-sources][warn] $*" >&2; }

# ── gh_api ────────────────────────────────────────────────────────────────────
gh_api() {
  local method="$1" url="$2"
  shift 2
  local attempt=0 max_retries=3

  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$HEADER_FILE" \
      "$@" "$url" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$body"; return 1; fi
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      if [[ "$wait" -gt 0 && "$wait" -lt 3700 ]]; then
        info "  rate limited — waiting ${wait}s (attempt ${attempt}/${max_retries})"
        sleep "$wait"
      else
        info "  rate limited — backing off 60s (attempt ${attempt}/${max_retries})"
        sleep 60
      fi
      continue
    elif [[ "$http_code" == "404" || "$http_code" == "409" || "$http_code" == "422" ]]; then
      echo "$body"; return 1
    elif [[ "$http_code" -ge 500 ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$body"; return 1; fi
      info "  server error ${http_code} — retrying in 10s"
      sleep 10; continue
    fi
    echo "$body"; return 0
  done
}

# ── merge_upstream ────────────────────────────────────────────────────────────
# Fast-forward FORK/BRANCH to its upstream. Falls back to force-reset if
# merge-upstream reports a divergence.
merge_upstream() {
  local fork="$1" branch="$2" upstream="${3:-}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  [dry-run] would merge upstream: ${fork}@${branch}"
    return 0
  fi

  local result merge_type message
  result=$(gh_api POST "${API}/repos/${fork}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"${branch}\"}" 2>&1) || true

  merge_type=$(echo "$result" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print(d.get("merge_type","error"))' \
    2>/dev/null || echo "error")
  message=$(echo "$result" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print(d.get("message",""))' \
    2>/dev/null || echo "")

  case "$merge_type" in
    fast-forward) info "  fast-forwarded: ${fork}@${branch}"; return 0 ;;
    none)         info "  already up-to-date: ${fork}@${branch}"; return 0 ;;
    merge)        info "  merged: ${fork}@${branch}"; return 0 ;;
  esac

  # Diverged — attempt force-reset to upstream HEAD if we know the upstream
  if [[ -n "$upstream" ]]; then
    warn "  merge-upstream failed (${message}) — force-resetting to ${upstream}@${branch}"
    force_reset_to_upstream "$fork" "$branch" "$upstream"
  else
    warn "  merge-upstream failed for ${fork}@${branch}: ${message}"
    return 1
  fi
}

force_reset_to_upstream() {
  local fork="$1" branch="$2" upstream="$3"

  local ref_result sha
  ref_result=$(gh_api GET "${API}/repos/${upstream}/git/ref/heads/${branch}") || {
    warn "  force-reset: could not fetch upstream ref ${upstream}@${branch}"; return 1
  }
  sha=$(echo "$ref_result" | python3 -c \
    'import sys,json; print(json.load(sys.stdin).get("object",{}).get("sha",""))' \
    2>/dev/null || echo "")
  [[ -n "$sha" ]] || { warn "  force-reset: could not parse upstream SHA"; return 1; }

  local patch_result
  patch_result=$(gh_api PATCH "${API}/repos/${fork}/git/refs/heads/${branch}" \
    -H "Content-Type: application/json" \
    -d "{\"sha\":\"${sha}\",\"force\":true}") || {
    warn "  force-reset failed for ${fork}@${branch}"; return 1
  }
  local new_sha
  new_sha=$(echo "$patch_result" | python3 -c \
    'import sys,json; print(json.load(sys.stdin).get("object",{}).get("sha",""))' \
    2>/dev/null || echo "")
  [[ -n "$new_sha" ]] && info "  force-reset to ${new_sha:0:7}" || \
    { warn "  force-reset: unexpected response"; return 1; }
}

# ── budget check ──────────────────────────────────────────────────────────────
over_budget() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  (( elapsed >= BUDGET_SECONDS ))
}

# ── load registry ─────────────────────────────────────────────────────────────
load_registry() {
  if [[ -n "$REGISTRY_FILE" ]]; then
    [[ -f "$REGISTRY_FILE" ]] || { warn "REGISTRY_FILE not found: $REGISTRY_FILE"; exit 1; }
    cat "$REGISTRY_FILE"
    return
  fi

  if [[ -n "$REGISTRY_REPO" ]]; then
    info "Fetching registry from ${REGISTRY_REPO}@${REGISTRY_BRANCH}:${REGISTRY_PATH}"
    local encoded_path="${REGISTRY_PATH//\//%2F}"
    local result
    result=$(gh_api GET \
      "${API}/repos/${REGISTRY_REPO}/contents/${REGISTRY_PATH}?ref=${REGISTRY_BRANCH}") || {
      warn "Could not fetch registry from ${REGISTRY_REPO}"; exit 1
    }
    echo "$result" | python3 -c \
      'import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d["content"]).decode())'
    return
  fi

  warn "No registry source: set REGISTRY_FILE or REGISTRY_REPO"
  exit 1
}

# ── step 1: sync core upstream ────────────────────────────────────────────────
sync_core_upstream() {
  local registry="$1"

  local core_repo core_branch core_target strategy
  core_repo=$(echo "$registry" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); c=d.get("upstream_core",{}); print(c.get("repo",""))' \
    2>/dev/null || echo "")
  [[ -z "$core_repo" ]] && { info "No upstream_core defined — skipping"; return 0; }

  core_branch=$(echo "$registry" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["upstream_core"].get("branch","main"))' 2>/dev/null)
  core_target=$(echo "$registry" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["upstream_core"].get("target_branch","main"))' 2>/dev/null)
  strategy=$(echo "$registry" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["upstream_core"].get("sync_strategy","merge-upstream"))' 2>/dev/null)

  info "Core upstream: ${core_repo}@${core_branch} → ${GITHUB_OWNER}/$(echo "$core_repo" | cut -d/ -f2)@${core_target}"

  [[ "$strategy" == "none" ]] && { info "  strategy=none — skipping"; return 0; }

  # The fork lives under GITHUB_OWNER; the upstream is core_repo
  local fork_name; fork_name=$(echo "$core_repo" | cut -d/ -f2)
  merge_upstream "${GITHUB_OWNER}/${fork_name}" "$core_target" "$core_repo" && \
    (( synced++ )) || (( failed++ )) || true
}

# ── step 2: sync projects ─────────────────────────────────────────────────────
sync_projects() {
  local registry="$1"

  local projects_json
  projects_json=$(echo "$registry" | python3 -c "
import sys, json
d = json.load(sys.stdin)
projects = d.get('projects', [])
filter_val = '${REPO_FILTER}'
for p in projects:
    if filter_val and filter_val not in p.get('name',''):
        continue
    print(json.dumps(p))
")

  local total current=0
  total=$(echo "$projects_json" | grep -c '^{' || echo 0)
  info "Projects to process: ${total}"

  while IFS= read -r project_json; do
    [[ -z "$project_json" ]] && continue

    over_budget && { info "Time budget reached — stopping early"; break; }

    (( current++ )) || true

    local name repo branch upstream upstream_branch strategy
    name=$(echo "$project_json" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("name","?"))' 2>/dev/null)
    repo=$(echo "$project_json" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("repo",""))' 2>/dev/null)
    branch=$(echo "$project_json" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("default_branch","main"))' 2>/dev/null)
    upstream=$(echo "$project_json" | python3 -c \
      'import sys,json; d=json.load(sys.stdin); print(d.get("upstream") or "")' 2>/dev/null)
    upstream_branch=$(echo "$project_json" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("upstream_branch","main"))' 2>/dev/null)
    strategy=$(echo "$project_json" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("sync_strategy","none"))' 2>/dev/null)

    info "[${current}/${total}] ${name} (${repo}@${branch}, strategy: ${strategy})"

    if [[ "$strategy" == "none" || -z "$upstream" ]]; then
      info "  no upstream — skipping"
      (( skipped++ )) || true
      continue
    fi

    # repo field may already be owner/repo under GITHUB_OWNER, or it may be
    # the upstream. Normalise: the fork we sync is always GITHUB_OWNER/<name>.
    local fork="${GITHUB_OWNER}/${name}"

    # Verify the fork exists before trying to sync
    local fork_check
    fork_check=$(gh_api GET "${API}/repos/${fork}" 2>/dev/null | \
      python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' \
      2>/dev/null || echo "")
    if [[ -z "$fork_check" ]]; then
      warn "  repo ${fork} not found under ${GITHUB_OWNER} — skipping"
      (( skipped++ )) || true
      continue
    fi

    merge_upstream "$fork" "$branch" "$upstream" && \
      (( synced++ )) || (( failed++ )) || true

  done <<< "$projects_json"
}

# ── main ──────────────────────────────────────────────────────────────────────
[[ "$DRY_RUN" == "true" ]] && info "DRY RUN — no changes will be made"
info "GITHUB_OWNER:   ${GITHUB_OWNER}"
info "SKIP_CORE:      ${SKIP_CORE}"
info "SKIP_PROJECTS:  ${SKIP_PROJECTS}"
info "BUDGET:         ${BUDGET_MINUTES}m"
[[ -n "$REPO_FILTER" ]] && info "REPO_FILTER:    ${REPO_FILTER}"

REGISTRY=$(load_registry)

[[ "$SKIP_CORE"     != "true" ]] && sync_core_upstream "$REGISTRY"
[[ "$SKIP_PROJECTS" != "true" ]] && sync_projects      "$REGISTRY"

elapsed=$(( $(date +%s) - START_TIME ))
echo ""
echo "========================================"
echo " sync-registry-sources complete"
echo " Elapsed  : ${elapsed}s"
echo " Synced   : ${synced}"
echo " Failed   : ${failed}"
echo " Skipped  : ${skipped}"
echo "========================================"

[[ "$failed" -eq 0 ]]
