#!/usr/bin/env bash
# scripts/sync-to-bugzilla.sh
#
# Parses commits and PR titles for Bugzilla bug IDs and updates the
# corresponding bugs with status, environment, and a comment linking
# the commit/PR to the bug.
#
# Called by sync-to-bugzilla.yml on push to main.
#
# Usage:
#   sync-to-bugzilla.sh [--dry-run] [--since COMMIT_SHA] [--pr PR_NUMBER]
#
# Required env vars:
#   BZ_URL      — Bugzilla instance base URL (from secret)
#   BZ_API_KEY  — Bugzilla API key (from secret)
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   GH_TOKEN    — GitHub PAT for reading PR data
#
# Optional env vars:
#   BZ_DRY_RUN  — "true" to log without writing
#   GITHUB_SHA  — current commit SHA (set automatically by Actions)
#   GITHUB_REF  — current ref (set automatically by Actions)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/bugzilla-api.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"

info() { echo "[sync-to-bugzilla] $*" >&2; }
warn() { echo "[sync-to-bugzilla][warn] $*" >&2; }

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN="${BZ_DRY_RUN:-false}"
SINCE_SHA=""
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --since)     SINCE_SHA="$2"; shift 2 ;;
    --pr)        PR_NUMBER="$2"; shift 2 ;;
    *)           warn "Unknown arg: $1"; shift ;;
  esac
done

export BZ_DRY_RUN="$DRY_RUN"

# ── Pre-flight ────────────────────────────────────────────────────────────────
if ! bz_is_configured; then
  warn "BZ_URL or BZ_API_KEY not set — Bugzilla integration not configured. Skipping."
  exit 0
fi

# Load config
CONFIG="$(cd "${SCRIPT_DIR}/.." && pwd)/config/bugzilla.yml"
if [[ ! -f "$CONFIG" ]]; then
  warn "config/bugzilla.yml not found — skipping"
  exit 0
fi

PRODUCT=$(python3 -c "import yaml,sys; c=yaml.safe_load(open('${CONFIG}')); print(c.get('product',''))" 2>/dev/null)
if [[ -z "$PRODUCT" ]]; then
  warn "config/bugzilla.yml: product not set — run onboard-bugzilla.yml first"
  exit 0
fi

DEFAULT_COMPONENT=$(python3 -c "
import yaml,sys
c=yaml.safe_load(open('${CONFIG}'))
print(c.get('default_component','General'))
" 2>/dev/null)

# ── Extract bug IDs from text ─────────────────────────────────────────────────
extract_bug_ids() {
  local text="$1"
  python3 -c "
import re, sys, yaml

text = sys.argv[1]
config = yaml.safe_load(open('${CONFIG}'))
patterns = config.get('commit_patterns', [
    r'Bug\s+(\d+)', r'bug\s+(\d+)', r'bz#(\d+)',
    r'bz:\s*(\d+)', r'\[bz-(\d+)\]',
])

found = set()
for pat in patterns:
    for m in re.finditer(pat, text):
        found.add(m.group(1))

for bug_id in sorted(found):
    print(bug_id)
" "$text" 2>/dev/null
}

# ── Get component for a commit/PR ─────────────────────────────────────────────
get_component() {
  local files_changed="$1"
  python3 -c "
import yaml, sys, fnmatch

config = yaml.safe_load(open('${CONFIG}'))
components = config.get('components', [])
files = sys.argv[1].split()

for entry in components:
    match = entry.get('match','')
    for f in files:
        if fnmatch.fnmatch(f, match):
            print(entry.get('component', '${DEFAULT_COMPONENT}'))
            sys.exit(0)

print('${DEFAULT_COMPONENT}')
" "$files_changed" 2>/dev/null || echo "$DEFAULT_COMPONENT"
}

# ── Process a single bug ID ───────────────────────────────────────────────────
process_bug() {
  local bug_id="$1" context="$2" url="$3" sha_short="$4"

  # Check the bug exists and is open
  local bug_json
  bug_json=$(bz_get_bug "$bug_id" 2>/dev/null) || {
    warn "Bug ${bug_id} not found or inaccessible — skipping"
    return 0
  }

  local status summary
  status=$(echo "$bug_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bugs=d.get('bugs',[])
if bugs: print(bugs[0].get('status',''))
" 2>/dev/null)
  summary=$(echo "$bug_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bugs=d.get('bugs',[])
if bugs: print(bugs[0].get('summary','')[:80])
" 2>/dev/null)

  info "Bug ${bug_id} [${status}]: ${summary}"

  # Build comment
  local comment
  comment="Automated update from fork-sync-all (${REPO:-unknown}):

${context}
Commit: ${url}
SHA: ${sha_short}
Ref: ${GITHUB_REF:-unknown}

This message was generated automatically by sync-to-bugzilla.sh."

  bz_add_comment "$bug_id" "$comment"

  # If bug is NEW or UNCONFIRMED, move to ASSIGNED to indicate work is in progress
  if [[ "$status" == "NEW" || "$status" == "UNCONFIRMED" ]]; then
    bz_update_bug "$bug_id" '{"status":"ASSIGNED"}' || true
    info "Bug ${bug_id}: status NEW → ASSIGNED"
  fi
}

# ── Process commits since SINCE_SHA ──────────────────────────────────────────
process_commits() {
  local since="${1:-HEAD~1}"
  local current="${GITHUB_SHA:-HEAD}"

  info "Scanning commits ${since}..${current} for bug references..."

  local commits
  commits=$(git log --oneline "${since}..${current}" 2>/dev/null || git log --oneline -10 2>/dev/null)

  if [[ -z "$commits" ]]; then
    info "No commits to scan"
    return 0
  fi

  local found_any=false
  while IFS= read -r line; do
    local sha msg
    sha=$(echo "$line" | awk '{print $1}')
    msg=$(echo "$line" | cut -d' ' -f2-)

    local bug_ids
    bug_ids=$(extract_bug_ids "$msg")
    if [[ -z "$bug_ids" ]]; then
      continue
    fi

    found_any=true
    local sha_short="${sha:0:8}"
    local commit_url="https://github.com/${REPO:-}/commit/${sha}"
    local context="Commit ${sha_short}: ${msg}"

    while IFS= read -r bug_id; do
      [[ -z "$bug_id" ]] && continue
      info "Found Bug ${bug_id} in commit ${sha_short}"
      process_bug "$bug_id" "$context" "$commit_url" "$sha_short"
    done <<< "$bug_ids"
  done <<< "$commits"

  if [[ "$found_any" == "false" ]]; then
    info "No bug references found in commits"
  fi
}

# ── Process a PR ──────────────────────────────────────────────────────────────
process_pr() {
  local pr_num="$1"
  info "Scanning PR #${pr_num} for bug references..."

  local pr_json
  pr_json=$(gh_get "https://api.github.com/repos/${REPO}/pulls/${pr_num}" 2>/dev/null) || {
    warn "Could not fetch PR #${pr_num}"
    return 0
  }

  local title body
  title=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
  body=$(echo "$pr_json"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('body','') or '')" 2>/dev/null)
  local pr_url="https://github.com/${REPO}/pull/${pr_num}"

  local combined="${title} ${body}"
  local bug_ids
  bug_ids=$(extract_bug_ids "$combined")

  if [[ -z "$bug_ids" ]]; then
    info "No bug references found in PR #${pr_num}"
    return 0
  fi

  while IFS= read -r bug_id; do
    [[ -z "$bug_id" ]] && continue
    info "Found Bug ${bug_id} in PR #${pr_num}: ${title}"
    local context="PR #${pr_num}: ${title}"
    process_bug "$bug_id" "$context" "$pr_url" "pr-${pr_num}"
  done <<< "$bug_ids"
}

# ── Main ──────────────────────────────────────────────────────────────────────
info "Starting Bugzilla sync (dry_run=${DRY_RUN})"
info "Instance: ${BZ_URL}"
info "Product:  ${PRODUCT}"

if [[ -n "$PR_NUMBER" ]]; then
  process_pr "$PR_NUMBER"
fi

if [[ -n "$SINCE_SHA" ]]; then
  process_commits "$SINCE_SHA"
elif [[ -z "$PR_NUMBER" ]]; then
  # Default: scan last commit
  process_commits "HEAD~1"
fi

info "Bugzilla sync complete"
