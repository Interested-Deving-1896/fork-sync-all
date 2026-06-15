#!/usr/bin/env bash
#
# scripts/sync-in-client.sh — register OSP-bound repos as Sync-in workspaces
#
# For each OSP-bound repo (or a filtered subset), creates or updates a
# Sync-in workspace on the configured server instance. Workspaces map
# one-to-one with GitHub repos: the workspace name matches the repo name,
# and the workspace root is the repo's default branch checkout path.
#
# ── Actions ───────────────────────────────────────────────────────────────────
#
#   register   — create workspace for each repo if it doesn't exist
#   sync       — trigger a sync on all registered workspaces
#   list       — list all workspaces on the server
#   deregister — remove workspace (requires REPO_FILTER to avoid mass delete)
#
# ── Required env vars ─────────────────────────────────────────────────────────
#
#   SYNC_IN_SERVER_URL   — base URL of the Sync-in instance
#   SYNC_IN_ADMIN_TOKEN  — admin API token
#   GH_TOKEN             — GitHub PAT (for listing OSP-bound repos)
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#
#   ACTION        — register | sync | list | deregister (default: list)
#   SOURCE_ORG    — GitHub org to register repos from (default: OpenOS-Project-OSP)
#   REPO_FILTER   — only process repos whose name contains this substring
#   DRY_RUN       — "true" = report without making changes
#   WORKSPACE_DIR — base directory for workspace paths on the server
#                   (default: /workspaces)

set -uo pipefail

: "${SYNC_IN_SERVER_URL:?SYNC_IN_SERVER_URL is required}"
: "${SYNC_IN_ADMIN_TOKEN:?SYNC_IN_ADMIN_TOKEN is required}"

ACTION="${ACTION:-list}"
SOURCE_ORG="${SOURCE_ORG:-OpenOS-Project-OSP}"
REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/includes/gh-api.sh
source "${SCRIPT_DIR}/includes/gh-api.sh"

info() { echo "[sync-in-client] $*" >&2; }
warn() { echo "[sync-in-client][warn] $*" >&2; }
dry()  { echo "[sync-in-client][dry-run] $*" >&2; }

GH_API="https://api.github.com"

# ── Sync-in API helpers ───────────────────────────────────────────────────────
_si_get() {
  local path="$1"
  curl -sf \
    -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
    -H "Accept: application/json" \
    "${SYNC_IN_SERVER_URL}${path}" 2>/dev/null || echo "{}"
}

_si_post() {
  local path="$1" body="$2"
  curl -sf -X POST \
    -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${SYNC_IN_SERVER_URL}${path}" 2>/dev/null || echo "{}"
}

_si_delete() {
  local path="$1"
  curl -sf -X DELETE \
    -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
    "${SYNC_IN_SERVER_URL}${path}" 2>/dev/null
}

# ── list repos from GitHub org ────────────────────────────────────────────────
_list_repos() {
  local cursor="" has_next=true

  while [[ "$has_next" == "true" ]]; do
    local after_arg=""
    [[ -n "$cursor" ]] && after_arg=", after: \\\"${cursor}\\\""
    local result
    result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GH_API}/graphql" \
      -d "{\"query\":\"{ organization(login: \\\"${SOURCE_ORG}\\\") { repositories(first: 100${after_arg}) { nodes { name defaultBranchRef { name } } pageInfo { hasNextPage endCursor } } } }\"}" \
      2>/dev/null || echo "{}")

    echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
repos=d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[])
for r in repos:
    branch=(r.get('defaultBranchRef') or {}).get('name','main')
    print(f\"{r['name']}|{branch}\")
" 2>/dev/null || true

    has_next=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pi=d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{})
print('true' if pi.get('hasNextPage') else 'false')
" 2>/dev/null || echo "false")

    cursor=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pi=d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{})
print(pi.get('endCursor',''))
" 2>/dev/null || echo "")

    [[ "$has_next" != "true" ]] && break
  done
}

# ── list ──────────────────────────────────────────────────────────────────────
_list() {
  info "Listing workspaces on ${SYNC_IN_SERVER_URL} ..."
  local result
  result=$(_si_get "/api/v1/workspaces")
  echo "$result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
workspaces=d if isinstance(d,list) else d.get('workspaces',d.get('data',[]))
print(f'Workspaces: {len(workspaces)}')
for w in workspaces:
    name=w.get('name',w.get('id','?'))
    status=w.get('status','?')
    print(f'  {name}: {status}')
" 2>/dev/null || echo "$result"
}

# ── register ──────────────────────────────────────────────────────────────────
_register() {
  : "${GH_TOKEN:?GH_TOKEN is required for register action}"

  info "Registering ${SOURCE_ORG} repos as Sync-in workspaces ..."
  [[ -n "$REPO_FILTER" ]] && info "Filter: '${REPO_FILTER}'"

  local registered=0 skipped=0 failed=0

  while IFS='|' read -r repo_name default_branch; do
    [[ -z "$repo_name" ]] && continue
    [[ -n "$REPO_FILTER" && "$repo_name" != *"$REPO_FILTER"* ]] && { (( skipped++ )) || true; continue; }

    local workspace_path="${WORKSPACE_DIR}/${repo_name}"
    local payload
    payload=$(python3 -c "
import json
print(json.dumps({
    'name': '${repo_name}',
    'path': '${workspace_path}',
    'source': {
        'type': 'github',
        'org': '${SOURCE_ORG}',
        'repo': '${repo_name}',
        'branch': '${default_branch}'
    }
}))
")

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would register workspace: ${repo_name} → ${workspace_path}"
      (( registered++ )) || true
      continue
    fi

    local result http_code
    result=$(curl -sf -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${SYNC_IN_SERVER_URL}/api/v1/workspaces" 2>/dev/null || echo -e "\n000")
    http_code=$(echo "$result" | tail -1)

    if [[ "$http_code" =~ ^2 ]]; then
      info "  ✓ ${repo_name}"
      (( registered++ )) || true
    elif [[ "$http_code" == "409" ]]; then
      info "  ~ ${repo_name} (already exists)"
      (( skipped++ )) || true
    else
      warn "  ✗ ${repo_name} (HTTP ${http_code})"
      (( failed++ )) || true
    fi
  done < <(_list_repos)

  info "Done. registered=${registered} skipped=${skipped} failed=${failed}"
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# ── sync ──────────────────────────────────────────────────────────────────────
_sync() {
  info "Triggering sync on all workspaces ..."

  local workspaces_json
  workspaces_json=$(_si_get "/api/v1/workspaces")
  local workspace_names
  mapfile -t workspace_names < <(echo "$workspaces_json" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ws=d if isinstance(d,list) else d.get('workspaces',d.get('data',[]))
for w in ws:
    name=w.get('name',w.get('id',''))
    if name: print(name)
" 2>/dev/null || true)

  local triggered=0 failed=0
  for name in "${workspace_names[@]}"; do
    [[ -z "$name" ]] && continue
    [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]] && continue

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would sync workspace: ${name}"
      (( triggered++ )) || true
      continue
    fi

    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
      "${SYNC_IN_SERVER_URL}/api/v1/workspaces/${name}/sync" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
      (( triggered++ )) || true
    else
      warn "  ✗ ${name} sync failed (HTTP ${http_code})"
      (( failed++ )) || true
    fi
  done

  info "Done. triggered=${triggered} failed=${failed}"
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# ── deregister ────────────────────────────────────────────────────────────────
_deregister() {
  [[ -z "$REPO_FILTER" ]] && { warn "REPO_FILTER required for deregister to prevent mass deletion"; return 1; }
  info "Deregistering workspaces matching '${REPO_FILTER}' ..."

  local workspaces_json
  workspaces_json=$(_si_get "/api/v1/workspaces")
  local removed=0 failed=0

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would deregister workspace: ${name}"
      (( removed++ )) || true
      continue
    fi
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE \
      -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
      "${SYNC_IN_SERVER_URL}/api/v1/workspaces/${name}" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^2 ]]; then
      info "  ✓ removed ${name}"
      (( removed++ )) || true
    else
      warn "  ✗ ${name} (HTTP ${http_code})"
      (( failed++ )) || true
    fi
  done < <(echo "$workspaces_json" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ws=d if isinstance(d,list) else d.get('workspaces',d.get('data',[]))
for w in ws:
    name=w.get('name',w.get('id',''))
    if name and '${REPO_FILTER}' in name: print(name)
" 2>/dev/null || true)

  info "Done. removed=${removed} failed=${failed}"
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$ACTION" in
  list)        _list        ;;
  register)    _register    ;;
  sync)        _sync        ;;
  deregister)  _deregister  ;;
  *)
    warn "Unknown ACTION '${ACTION}'. Use: list | register | sync | deregister"
    exit 1
    ;;
esac
