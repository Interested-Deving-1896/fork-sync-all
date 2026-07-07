#!/usr/bin/env bash
#
# Re-syncs all repos registered in registered-imports.json.
#
# For each entry, bare-clones the source URL and pushes all branches + tags
# to the Interested-Deving-1896 counterpart. Platform-specific tokens are
# used automatically when available.
#
# registered-imports.json schema (array of objects):
#   {
#     "source_url":  "https://gitlab.com/some-group/some-repo",
#     "target_name": "some-repo",
#     "platform":    "gitlab",
#     "added":       "2026-05-02T18:00:00Z"
#   }
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT (repo + workflow scopes)
#   GITHUB_OWNER  — Interested-Deving-1896
#
# Optional env vars (for private sources):
#   GITLAB_TOKEN      — GitLab PAT with read_repository scope
#   BITBUCKET_TOKEN   — Bitbucket app password
#   GITEA_TOKEN       — Gitea PAT

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
SOURCE_FILTER="${SOURCE_FILTER:-}"
# FORCE_SYNC=true bypasses the pushed_at gate (workflow_dispatch input).
FORCE_SYNC="${FORCE_SYNC:-false}"

IMPORTS_FILE="registered-imports.json"


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

info() { echo "[sync-registered-imports] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# shellcheck disable=SC2120
sanitize() {
  # Accepts either a positional argument or stdin.
  local out
  if [[ $# -gt 0 ]]; then
    out="$1"
  else
    out=$(cat)
  fi
  echo "$out" \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    | sed "s/${GITLAB_TOKEN:-NOGLTOKEN}/***TOKEN***/g" \
    | sed "s/${BITBUCKET_TOKEN:-NOBBTOKEN}/***TOKEN***/g" \
    | sed "s/${GITEA_TOKEN:-NOGTTOKEN}/***TOKEN***/g"
}

# Build authenticated clone URL for a given source URL + platform
auth_clone_url() {
  local url="$1" platform="$2"
  case "$platform" in
    github)
      echo "${url/https:\/\//https://x-access-token:${GH_TOKEN}@}.git"
      ;;
    gitlab)
      if [ -n "${GITLAB_TOKEN:-}" ]; then
        echo "${url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}.git"
      else
        echo "${url}.git"
      fi
      ;;
    bitbucket)
      if [ -n "${BITBUCKET_TOKEN:-}" ]; then
        echo "${url/https:\/\/bitbucket.org\//https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/}.git"
      else
        echo "${url}.git"
      fi
      ;;
    gitea)
      if [ -n "${GITEA_TOKEN:-}" ]; then
        echo "${url/https:\/\//https://x-access-token:${GITEA_TOKEN}@}.git"
      else
        echo "${url}.git"
      fi
      ;;
    *)
      echo "${url}.git"
      ;;
  esac
}

# ── git push with retry ───────────────────────────────────────────────────────
# Source platforms (GitLab, Bitbucket, Gitea) and GitHub all enforce push rate
# limits. Retry up to 3 times with linear backoff before giving up.
git_push_retry() {
  local remote="$1" refspec="$2" max_retries=3 attempt=0
  while true; do
    local push_out push_rc=0
    push_out=$(git push "$remote" "$refspec" 2>&1) || push_rc=$?
    sanitize <<< "$push_out"
    if [[ $push_rc -eq 0 ]]; then
      return 0
    fi
    # GH006: branch protection rules block the push — retrying won't help.
    # Return 2 so the caller can treat this as a permanent skip rather than
    # a transient failure worth counting against the run.
    if echo "$push_out" | grep -qF "GH006"; then
      warn "Push of ${refspec} blocked by branch protection (GH006) — skipping"
      return 2
    fi
    (( attempt++ )) || true
    if (( attempt > max_retries )); then
      warn "Push of ${refspec} failed after ${max_retries} attempts"
      return 1
    fi
    local wait=$(( attempt * 15 ))
    warn "[push-retry] attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done
}

# ---------------------------------------------------------------------------
# prefetch_repo_metadata <target_name> [<target_name> ...]
# Fetches pushedAt + existence for all target repos in a single GraphQL call.
# Populates _REPO_PUSHED_AT and _REPO_EXISTS associative arrays.
# Falls back gracefully — missing entries treated as "needs sync / not exists".
# ---------------------------------------------------------------------------
declare -A _REPO_PUSHED_AT=()
declare -A _REPO_EXISTS=()

prefetch_repo_metadata() {
  local names=("$@")
  [[ ${#names[@]} -eq 0 ]] && return 0

  # Build GraphQL aliases: one per repo name
  local aliases="" i=0
  for name in "${names[@]}"; do
    local safe
    safe=$(echo "$name" | tr '-' '_' | tr '.' '_' | sed 's/^[0-9]/_&/')
    aliases+="r${i}: repository(owner: \\\"${GITHUB_OWNER}\\\", name: \\\"${name}\\\") { name pushedAt } "
    (( i++ )) || true
  done

  local result
  result=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.github.com/graphql" \
    -d "{\"query\":\"{ ${aliases} }\"}" 2>/dev/null || echo "{}")

  # Parse into associative arrays
  while IFS='|' read -r name pushed_at exists; do
    [[ -z "$name" ]] && continue
    _REPO_PUSHED_AT["$name"]="$pushed_at"
    _REPO_EXISTS["$name"]="$exists"
  done < <(echo "$result" | python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(sys.stdin).get('data', {})
for key, val in data.items():
    if not val:
        print('||false')
        continue
    name = val.get('name', '')
    pushed = val.get('pushedAt') or ''
    epoch = ''
    if pushed:
        try:
            epoch = str(int(datetime.fromisoformat(pushed.replace('Z','+00:00')).timestamp()))
        except Exception:
            pass
    print(f'{name}|{epoch}|true')
" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# target_pushed_since  <target_name> <cutoff_epoch>
# Uses pre-fetched metadata — no REST call.
# ---------------------------------------------------------------------------
target_pushed_since() {
  local target_name="$1" cutoff="$2"
  local pushed_at="${_REPO_PUSHED_AT[$target_name]:-}"
  [[ -z "$pushed_at" ]] && return 1  # not found — needs sync
  [[ "$pushed_at" -ge "$cutoff" ]]
}

# ensure_gh_repo <target_name>
# Creates the GitHub repo under GITHUB_OWNER if it does not already exist.
# Uses pre-fetched metadata for the existence check — only calls REST to create.
ensure_gh_repo() {
  local target_name="$1"
  local exists="${_REPO_EXISTS[$target_name]:-false}"

  if [[ "$exists" == "true" ]]; then
    return 0  # already exists — no REST call needed
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  [DRY_RUN] would create ${GITHUB_OWNER}/${target_name}"
    return 0
  fi
  info "  Creating ${GITHUB_OWNER}/${target_name}..."
  local create_out create_rc=0
  create_out=$(curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "https://api.github.com/orgs/${GITHUB_OWNER}/repos" \
    -d "{\"name\":\"${target_name}\",\"private\":false,\"auto_init\":false}" \
    2>&1) || create_rc=$?
  if [[ $create_rc -ne 0 ]]; then
    warn "  Failed to create ${GITHUB_OWNER}/${target_name}: ${create_out:0:200}"
    return 1
  fi
  # Mark as existing so subsequent calls in this run don't re-create
  _REPO_EXISTS["$target_name"]="true"
  info "  Created ${GITHUB_OWNER}/${target_name}."
}

sync_entry() {
  local source_url="$1" target_name="$2" platform="$3"

  info "──────────────────────────────────────────"
  info "${source_url}  →  github.com/${GITHUB_OWNER}/${target_name}"

  # Ensure the target repo exists before attempting to push
  ensure_gh_repo "$target_name" || { warn "Cannot ensure target repo — skipping"; return 1; }

  local clone_url
  clone_url=$(auth_clone_url "$source_url" "$platform")

  local work_dir
  work_dir=$(mktemp -d)

  # Clone
  local clone_out clone_rc=0
  clone_out=$(git clone --mirror "$clone_url" "$work_dir" 2>&1) || clone_rc=$?
  sanitize <<< "$clone_out"
  if [[ $clone_rc -ne 0 ]]; then
    warn "Clone failed for ${source_url} — skipping"
    rm -rf "$work_dir"
    return 1
  fi

  cd "$work_dir" || exit 1

  local gh_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${target_name}.git"
  local push_ok=true push_protected=false

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  [DRY_RUN] would push ${source_url} → ${GITHUB_OWNER}/${target_name}"
    cd /
    rm -rf "$work_dir"
    return 0
  fi

  # Push branches (no prune — preserves GitHub-only branches)
  # Exit 2 from git_push_retry means GH006 (branch protection) — treat as skip
  local branch_rc=0
  git_push_retry "$gh_url" '+refs/heads/*:refs/heads/*' || branch_rc=$?
  if [[ $branch_rc -eq 2 ]]; then
    push_protected=true
  elif [[ $branch_rc -ne 0 ]]; then
    push_ok=false
  fi

  # Push tags (non-fatal)
  local tags_out
  tags_out=$(git push "$gh_url" '+refs/tags/*:refs/tags/*' 2>&1) || true
  sanitize <<< "$tags_out"

  cd /
  rm -rf "$work_dir"

  if $push_protected; then
    warn "⏭ ${target_name} skipped — branch protection blocks push (GH006)"
    return 2
  elif $push_ok; then
    info "✅ ${target_name} done"
    return 0
  else
    warn "❌ ${target_name} push failed"
    return 1
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

if [ ! -f "$IMPORTS_FILE" ]; then
  info "No ${IMPORTS_FILE} found — nothing to sync."
  exit 0
fi

entry_count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$IMPORTS_FILE" 2>/dev/null || echo 0)

if [ "$entry_count" -eq 0 ]; then
  info "registered-imports.json is empty — nothing to sync."
  exit 0
fi

info "Found ${entry_count} registered import(s)."
echo ""

synced=0
failed=0
skipped=0

# Idempotency gate: skip entries whose GitHub target was pushed to within
# the last 75 minutes — the previous sync already landed. Falls back to
# syncing on any API error. FORCE_SYNC=true bypasses the gate entirely.
SYNC_CUTOFF=$(( $(date +%s) - 4500 ))  # 75 minutes
[[ "$FORCE_SYNC" == "true" ]] && SYNC_CUTOFF=0

# Pre-fetch pushed_at + existence for all target repos in one GraphQL call.
# Replaces O(N) per-repo REST calls with a single batched request.
info "Pre-fetching repo metadata via GraphQL (1 call for all ${entry_count} repos)..."
mapfile -t _all_targets < <(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for e in data:
    print(e['target_name'])
" "$IMPORTS_FILE" 2>/dev/null)
prefetch_repo_metadata "${_all_targets[@]}"
info "Metadata pre-fetch complete."
echo ""

# Iterate entries via python3 to handle JSON safely
while IFS='|' read -r source_url target_name platform; do
    budget_check "$target_name" || break
  [ -z "$source_url" ] && continue
  [[ -n "$REPO_FILTER"    && "$target_name" != *"$REPO_FILTER"*  ]] && continue
  [[ -n "$SOURCE_FILTER"  && "$platform"    != "$SOURCE_FILTER"  ]] && continue

  # Skip if the target was already synced recently
  if target_pushed_since "$target_name" "$SYNC_CUTOFF"; then
    info "[$target_name] target pushed recently — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  local sync_rc=0
  sync_entry "$source_url" "$target_name" "$platform" || sync_rc=$?
  if [[ $sync_rc -eq 0 ]]; then
    synced=$((synced + 1))
  elif [[ $sync_rc -eq 2 ]]; then
    # GH006 branch protection — permanent skip, not a transient failure
    skipped=$((skipped + 1))
  else
    failed=$((failed + 1))
  fi
done < <(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for e in data:
    print('%s|%s|%s' % (e['source_url'], e['target_name'], e.get('platform','generic')))
" "$IMPORTS_FILE")

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
budget_report
[ "$failed" -eq 0 ] || exit 1
