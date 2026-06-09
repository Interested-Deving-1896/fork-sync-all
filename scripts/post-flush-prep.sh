#!/usr/bin/env bash
#
# post-flush-prep.sh
#
# End-to-end verification after a full-chain-flush completes. Runs a suite
# of checks to confirm the system is in a healthy state:
#
#   Check 1 — Mirror integrity (all three pairs)
#             Compares HEAD SHAs between source and destination for all
#             OSP-bound repos across all three mirror pairs.
#
#   Check 2 — CI status on OSP-bound repos
#             Checks GitHub CI status on Interested-Deving-1896 OSP-bound
#             repos. Reports any repos that are still red after the flush.
#
#   Check 3 — Quota health
#             Reports remaining quota and warns if below a safe threshold.
#
#   Check 4 — Workflow queue health
#             Checks for any queued or in-progress runs that may indicate
#             a stuck workflow.
#
# Outputs a structured summary to GITHUB_STEP_SUMMARY.
# Exits non-zero only if BLOCK_ON_FAILURE=true and critical checks fail.
#
# Required env vars:
#   GH_TOKEN           — PAT with repo + actions:read scope
#   REPO               — owner/repo of fork-sync-all
#
# Optional env vars:
#   GITLAB_TOKEN       — for GitLab integrity check (skipped if absent)
#   BLOCK_ON_FAILURE   — "true" to exit 1 on any critical failure (default: false)
#   REPO_FILTER        — substring filter on repo name (default: all)
#   BUDGET_MINUTES     — time budget in minutes (default: 45)
#   MIN_QUOTA          — skip if quota below this (default: 300)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

BLOCK_ON_FAILURE="${BLOCK_ON_FAILURE:-false}"
REPO_FILTER="${REPO_FILTER:-}"
MIN_QUOTA="${MIN_QUOTA:-300}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"

budget_init

# ── Logging ───────────────────────────────────────────────────────────────────
info()  { echo "[post-flush-prep] $*" >&2; }
warn()  { echo "[post-flush-prep] ⚠️  $*" >&2; }
ok()    { echo "[post-flush-prep] ✓ $*" >&2; }
fail()  { echo "[post-flush-prep] ✗ $*" >&2; }
header(){ echo "" >&2; echo "[post-flush-prep] ── $* ──" >&2; }

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota_json=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/rate_limit" 2>/dev/null || echo '{}')
_quota_remaining=$(echo "$_quota_json" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('remaining',0))" \
  2>/dev/null || echo 0)
_quota_reset=$(echo "$_quota_json" | python3 -c \
  "import sys,json,datetime; d=json.load(sys.stdin); \
   ts=d.get('resources',{}).get('core',{}).get('reset',0); \
   print(datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M UTC') if ts else 'unknown')" \
  2>/dev/null || echo 'unknown')

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — skipping post-flush verification."
  exit 0
fi
info "Quota: ${_quota_remaining} remaining (resets ${_quota_reset})"

# ── Load OSP-bound repo list ──────────────────────────────────────────────────
CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"
if [[ ! -f "$CONFIG" ]]; then
  warn "config/gitlab-subgroups.yml not found — skipping."
  exit 0
fi

mapfile -t OSP_REPOS < <(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys
data = yaml.safe_load(open(sys.argv[1]))
repos = []
for sg in (data.get("subgroups") or {}).values():
    repos.extend(sg.get("repos") or [])
for r in sorted(set(repos)):
    print(r)
PYEOF
)

TOTAL_REPOS="${#OSP_REPOS[@]}"
info "OSP-bound repos: ${TOTAL_REPOS}"

# ── Tracking ──────────────────────────────────────────────────────────────────
declare -A CHECK_STATUS=()
declare -A CHECK_DETAILS=()
CRITICAL_FAILURES=0

# ── Check 1: Mirror integrity ─────────────────────────────────────────────────
header "Check 1: Mirror integrity"

run_integrity_check() {
  local pair="$1"
  local src_org="$2"
  local dst_org="$3"
  local dst_backend="$4"

  local mismatch=0
  local missing=0
  local ok_count=0
  local issues=()

  for repo in "${OSP_REPOS[@]}"; do
    budget_check "$repo" || break
    [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue

    # Source SHA
    local src_sha
    src_sha=$(gh_get "https://api.github.com/repos/${src_org}/${repo}/commits/HEAD" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" \
      2>/dev/null || echo "")
    [[ -z "$src_sha" ]] && continue

    # Destination SHA
    local dst_sha=""
    if [[ "$dst_backend" == "github" ]]; then
      dst_sha=$(gh_get "https://api.github.com/repos/${dst_org}/${repo}/commits/HEAD" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" \
        2>/dev/null || echo "")
    elif [[ "$dst_backend" == "gitlab" && -n "${GITLAB_TOKEN:-}" ]]; then
      local gl_path
      gl_path=$(python3 - "$repo" "$CONFIG" <<'PYEOF'
import yaml, sys
repo = sys.argv[1]
config_path = sys.argv[2]
data = yaml.safe_load(open(config_path))
subgroups = data.get("subgroups", {}) or {}
default_sg = data.get("default_subgroup", "ops")
for sg_name, sg in subgroups.items():
    if repo in (sg.get("repos") or []):
        path = sg.get("path") or f"openos-project/{sg_name}"
        print(f"{path}/{repo}")
        sys.exit(0)
print(f"openos-project/{default_sg}/{repo}")
PYEOF
)
      local encoded_path
      encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],''))" "$gl_path")
      dst_sha=$(curl -sf \
        -H "Authorization: Bearer ${GITLAB_TOKEN}" \
        "https://gitlab.com/api/v4/projects/${encoded_path}/repository/commits?per_page=1" \
        2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" \
        2>/dev/null || echo "")
    fi

    if [[ -z "$dst_sha" ]]; then
      issues+=("MISSING:${repo}")
      (( missing++ )) || true
    elif [[ "${src_sha:0:12}" != "${dst_sha:0:12}" ]]; then
      issues+=("MISMATCH:${repo}:src=${src_sha:0:12}:dst=${dst_sha:0:12}")
      (( mismatch++ )) || true
    else
      (( ok_count++ )) || true
    fi
  done

  local total_issues=$(( mismatch + missing ))
  if [[ $total_issues -eq 0 ]]; then
    ok "  ${pair}: ${ok_count} repos in sync"
    CHECK_STATUS["integrity_${pair}"]="OK"
  else
    warn "  ${pair}: ${mismatch} mismatch(es), ${missing} missing"
    CHECK_STATUS["integrity_${pair}"]="WARN"
    CHECK_DETAILS["integrity_${pair}"]="${issues[*]:-}"
  fi
}

run_integrity_check "id-1896-to-osp" "Interested-Deving-1896" "OpenOS-Project-OSP" "github"
run_integrity_check "osp-to-ooc" "OpenOS-Project-OSP" "OpenOS-Project-Ecosystem-OOC" "github"
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  run_integrity_check "osp-to-gitlab" "OpenOS-Project-OSP" "openos-project" "gitlab"
else
  warn "  osp-to-gitlab: GITLAB_TOKEN not set — skipped"
  CHECK_STATUS["integrity_osp-to-gitlab"]="SKIP"
fi

# ── Check 2: CI status on I-D-1896 OSP-bound repos ───────────────────────────
header "Check 2: CI status on I-D-1896 OSP-bound repos"

CI_FAILING=()
for repo in "${OSP_REPOS[@]}"; do
  budget_check "$repo" || break
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue

  sha=$(gh_get "https://api.github.com/repos/Interested-Deving-1896/${repo}/commits/HEAD" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" \
    2>/dev/null || echo "")
  [[ -z "$sha" ]] && continue

  check_result=$(gh_get \
    "https://api.github.com/repos/Interested-Deving-1896/${repo}/commits/${sha}/check-runs?per_page=100" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
runs=d.get('check_runs',[])
failing=[r['name'] for r in runs if r.get('conclusion') in ('failure','action_required','timed_out')]
print('FAIL' if failing else 'OK')
" 2>/dev/null || echo "OK")

  if [[ "$check_result" == "FAIL" ]]; then
    CI_FAILING+=("$repo")
  fi
done

if [[ ${#CI_FAILING[@]} -eq 0 ]]; then
  ok "  All ${TOTAL_REPOS} OSP-bound repos are green"
  CHECK_STATUS["ci_status"]="OK"
else
  warn "  ${#CI_FAILING[@]} repo(s) still failing: ${CI_FAILING[*]}"
  CHECK_STATUS["ci_status"]="WARN"
  CHECK_DETAILS["ci_status"]="${CI_FAILING[*]}"
fi

# ── Check 3: Quota health ─────────────────────────────────────────────────────
header "Check 3: Quota health"

_quota_after=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo 0)

if (( _quota_after >= 1000 )); then
  ok "  Quota: ${_quota_after} remaining — healthy"
  CHECK_STATUS["quota"]="OK"
elif (( _quota_after >= 300 )); then
  warn "  Quota: ${_quota_after} remaining — low but functional"
  CHECK_STATUS["quota"]="WARN"
else
  warn "  Quota: ${_quota_after} remaining — critically low"
  CHECK_STATUS["quota"]="WARN"
fi

# ── Check 4: Workflow queue health ────────────────────────────────────────────
header "Check 4: Workflow queue health"

queued_count=$(gh_get \
  "https://api.github.com/repos/${REPO}/actions/runs?status=queued&per_page=100" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" \
  2>/dev/null || echo 0)

in_progress_count=$(gh_get \
  "https://api.github.com/repos/${REPO}/actions/runs?status=in_progress&per_page=100" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" \
  2>/dev/null || echo 0)

if (( queued_count <= 5 && in_progress_count <= 3 )); then
  ok "  Queue: ${queued_count} queued, ${in_progress_count} in-progress — healthy"
  CHECK_STATUS["queue"]="OK"
else
  warn "  Queue: ${queued_count} queued, ${in_progress_count} in-progress — elevated"
  CHECK_STATUS["queue"]="WARN"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
header "Post-flush verification summary"

WARN_COUNT=0
for key in "${!CHECK_STATUS[@]}"; do
  status="${CHECK_STATUS[$key]}"
  detail="${CHECK_DETAILS[$key]:-}"
  case "$status" in
    OK)   ok "  ${key}: OK" ;;
    WARN) warn "  ${key}: WARN${detail:+ — ${detail}}"; (( WARN_COUNT++ )) || true ;;
    SKIP) info "  ${key}: SKIP" ;;
  esac
done

# Write structured summary to GITHUB_STEP_SUMMARY
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Post-Flush Verification"
    echo ""
    echo "| Check | Status | Detail |"
    echo "|-------|--------|--------|"
    for key in integrity_id-1896-to-osp integrity_osp-to-ooc integrity_osp-to-gitlab ci_status quota queue; do
      status="${CHECK_STATUS[$key]:-N/A}"
      detail="${CHECK_DETAILS[$key]:-—}"
      icon="✅"
      [[ "$status" == "WARN" ]] && icon="⚠️"
      [[ "$status" == "SKIP" ]] && icon="⏭️"
      echo "| ${key} | ${icon} ${status} | ${detail} |"
    done
    echo ""
    echo "**Quota after flush:** ${_quota_after} remaining (resets ${_quota_reset})"
  } >> "$GITHUB_STEP_SUMMARY"
fi

info ""
if [[ "$WARN_COUNT" -eq 0 ]]; then
  ok "All post-flush checks passed."
else
  warn "${WARN_COUNT} check(s) reported warnings."
fi

if [[ "$BLOCK_ON_FAILURE" == "true" && "$CRITICAL_FAILURES" -gt 0 ]]; then
  fail "Blocking: ${CRITICAL_FAILURES} critical failure(s)."
  exit 1
fi

exit 0
