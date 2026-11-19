#!/usr/bin/env bash
# scripts/file-bugzilla-report.sh
#
# Files or updates a Bugzilla bug when a GitHub Actions workflow fails.
# Called by bugzilla-failure-report.yml on workflow_run: completed with
# conclusion: failure.
#
# Deduplication: if an open bug already exists for the same workflow,
# adds a comment rather than filing a new bug (controlled by
# config/bugzilla.yml failure_reporter.dedup_by_workflow).
#
# Usage:
#   file-bugzilla-report.sh [--dry-run]
#
# Required env vars:
#   BZ_URL           — Bugzilla instance base URL (from secret)
#   BZ_API_KEY       — Bugzilla API key (from secret)
#   REPO             — owner/repo
#   FAILED_WORKFLOW  — name of the workflow that failed
#   FAILED_RUN_ID    — GitHub Actions run ID
#   FAILED_RUN_URL   — URL to the failed run
#   FAILED_CONCLUSION — failure | cancelled | timed_out
#
# Optional env vars:
#   BZ_DRY_RUN       — "true" to log without writing
#   GH_TOKEN         — for fetching additional run details

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/bugzilla-api.sh"

info() { echo "[file-bugzilla-report] $*" >&2; }
warn() { echo "[file-bugzilla-report][warn] $*" >&2; }

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN="${BZ_DRY_RUN:-false}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
export BZ_DRY_RUN="$DRY_RUN"

# ── Pre-flight ────────────────────────────────────────────────────────────────
if ! bz_is_configured; then
  warn "BZ_URL or BZ_API_KEY not set — Bugzilla integration not configured. Skipping."
  exit 0
fi

: "${FAILED_WORKFLOW:?FAILED_WORKFLOW must be set}"
: "${FAILED_RUN_ID:?FAILED_RUN_ID must be set}"
: "${FAILED_RUN_URL:?FAILED_RUN_URL must be set}"
FAILED_CONCLUSION="${FAILED_CONCLUSION:-failure}"

CONFIG="$(cd "${SCRIPT_DIR}/.." && pwd)/config/bugzilla.yml"
if [[ ! -f "$CONFIG" ]]; then
  warn "config/bugzilla.yml not found — skipping"
  exit 0
fi

# Load config values
PRODUCT=$(python3 -c "import yaml; c=yaml.safe_load(open('${CONFIG}')); print(c.get('product',''))" 2>/dev/null)
if [[ -z "$PRODUCT" ]]; then
  warn "config/bugzilla.yml: product not set — run onboard-bugzilla.yml first"
  exit 0
fi

DEFAULT_COMPONENT=$(python3 -c "
import yaml; c=yaml.safe_load(open('${CONFIG}')); print(c.get('default_component','General'))
" 2>/dev/null)

DEDUP=$(python3 -c "
import yaml; c=yaml.safe_load(open('${CONFIG}'))
fr=c.get('failure_reporter',{})
print(str(fr.get('dedup_by_workflow',True)).lower())
" 2>/dev/null || echo "true")

MAX_COMMENTS=$(python3 -c "
import yaml; c=yaml.safe_load(open('${CONFIG}'))
fr=c.get('failure_reporter',{})
print(fr.get('max_comments_before_new_bug',10))
" 2>/dev/null || echo "10")

# Check if this workflow is excluded
EXCLUDED=$(python3 -c "
import yaml,sys
c=yaml.safe_load(open('${CONFIG}'))
excluded=c.get('failure_reporter',{}).get('excluded_workflows',[]) or []
wf=sys.argv[1]
print('true' if wf in excluded else 'false')
" "$FAILED_WORKFLOW" 2>/dev/null || echo "false")

if [[ "$EXCLUDED" == "true" ]]; then
  info "Workflow '${FAILED_WORKFLOW}' is in excluded_workflows — skipping"
  exit 0
fi

# ── Determine severity and component ─────────────────────────────────────────
get_severity() {
  python3 -c "
import yaml,sys
c=yaml.safe_load(open('${CONFIG}'))
sm=c.get('severity_map',{})
wf=sys.argv[1]
if wf in sm.get('critical_workflows',[]):
    print(sm.get('critical_severity','critical'))
elif wf in sm.get('high_workflows',[]):
    print(sm.get('high_severity','major'))
else:
    print(sm.get('default_severity','normal'))
" "$FAILED_WORKFLOW" 2>/dev/null || echo "normal"
}

get_priority() {
  local severity="$1"
  python3 -c "
import yaml,sys
c=yaml.safe_load(open('${CONFIG}'))
pm=c.get('priority_map',{})
print(pm.get(sys.argv[1],'P3'))
" "$severity" 2>/dev/null || echo "P3"
}

get_component() {
  python3 -c "
import yaml,sys,fnmatch
c=yaml.safe_load(open('${CONFIG}'))
components=c.get('components',[]) or []
wf=sys.argv[1]
for entry in components:
    if fnmatch.fnmatch(wf, entry.get('match','')):
        print(entry.get('component','${DEFAULT_COMPONENT}'))
        sys.exit(0)
print('${DEFAULT_COMPONENT}')
" "$FAILED_WORKFLOW" 2>/dev/null || echo "$DEFAULT_COMPONENT"
}

SEVERITY=$(get_severity)
PRIORITY=$(get_priority "$SEVERITY")
COMPONENT=$(get_component)

info "Workflow: ${FAILED_WORKFLOW}"
info "Run:      ${FAILED_RUN_URL}"
info "Severity: ${SEVERITY} / Priority: ${PRIORITY} / Component: ${COMPONENT}"

# ── Build summary and description ─────────────────────────────────────────────
SUMMARY="[FSA] ${FAILED_WORKFLOW} failed (${FAILED_CONCLUSION})"

DESCRIPTION="A GitHub Actions workflow failed in fork-sync-all.

Workflow:   ${FAILED_WORKFLOW}
Conclusion: ${FAILED_CONCLUSION}
Run ID:     ${FAILED_RUN_ID}
Run URL:    ${FAILED_RUN_URL}
Repository: ${REPO:-unknown}

This bug was filed automatically by file-bugzilla-report.sh.
To investigate: open the run URL above and check the failed step logs."

COMMENT="Recurrence: ${FAILED_WORKFLOW} failed again.

Conclusion: ${FAILED_CONCLUSION}
Run ID:     ${FAILED_RUN_ID}
Run URL:    ${FAILED_RUN_URL}

Automated comment from file-bugzilla-report.sh."

# ── Deduplication: search for existing open bug ───────────────────────────────
find_existing_bug() {
  local search_summary
  # URL-encode the workflow name for the query
  search_summary=$(python3 -c "
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1]))
" "[FSA] ${FAILED_WORKFLOW}" 2>/dev/null || echo "")

  if [[ -z "$search_summary" ]]; then
    echo ""
    return 0
  fi

  local result
  result=$(bz_search "product=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PRODUCT}'))" 2>/dev/null)&summary=${search_summary}&status=NEW&status=UNCONFIRMED&status=ASSIGNED&status=REOPENED" 2>/dev/null) || {
    echo ""
    return 0
  }

  python3 -c "
import json,sys
d=json.load(sys.stdin)
bugs=d.get('bugs',[])
if bugs:
    # Return the most recently updated open bug
    bugs.sort(key=lambda b: b.get('last_change_time',''), reverse=True)
    print(bugs[0]['id'])
" <<< "$result" 2>/dev/null || echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
info "Starting failure report (dry_run=${DRY_RUN})"

EXISTING_BUG=""
if [[ "$DEDUP" == "true" ]]; then
  info "Checking for existing open bug for '${FAILED_WORKFLOW}'..."
  EXISTING_BUG=$(find_existing_bug)
fi

if [[ -n "$EXISTING_BUG" ]]; then
  # Count existing comments to decide whether to add or file new
  comment_count=$(bz_get "bug/${EXISTING_BUG}/comment" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
comments=d.get('bugs',{}).get('${EXISTING_BUG}',{}).get('comments',[])
print(len(comments))
" 2>/dev/null || echo "0")

  if [[ "$comment_count" -ge "$MAX_COMMENTS" ]]; then
    info "Bug ${EXISTING_BUG} has ${comment_count} comments (>= ${MAX_COMMENTS}) — filing new bug"
    EXISTING_BUG=""
  else
    info "Adding comment to existing bug ${EXISTING_BUG} (${comment_count} existing comments)"
    bz_add_comment "$EXISTING_BUG" "$COMMENT"
    info "Done — updated bug ${EXISTING_BUG}: ${BZ_URL%/}/show_bug.cgi?id=${EXISTING_BUG}"
    exit 0
  fi
fi

# File a new bug
info "Filing new bug: ${SUMMARY}"
BUG_ID=$(bz_file_bug "$PRODUCT" "$COMPONENT" "$SUMMARY" "$DESCRIPTION" "$SEVERITY" "$PRIORITY")

if [[ -z "$BUG_ID" || "$BUG_ID" == "0" ]]; then
  warn "Failed to file bug"
  exit 1
fi

info "Filed bug ${BUG_ID}: ${BZ_URL%/}/show_bug.cgi?id=${BUG_ID}"

# Output for GitHub Actions step summary
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY_EOF

## Bugzilla Report

Filed bug **${BUG_ID}**: [${SUMMARY}](${BZ_URL%/}/show_bug.cgi?id=${BUG_ID})

| Field | Value |
|---|---|
| Workflow | ${FAILED_WORKFLOW} |
| Severity | ${SEVERITY} |
| Priority | ${PRIORITY} |
| Component | ${COMPONENT} |
| Run | [${FAILED_RUN_ID}](${FAILED_RUN_URL}) |
SUMMARY_EOF
fi
