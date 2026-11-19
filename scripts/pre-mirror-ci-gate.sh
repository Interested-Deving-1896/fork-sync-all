#!/usr/bin/env bash
#
# pre-mirror-ci-gate.sh
#
# Checks CI status on all OSP-bound repos in Interested-Deving-1896 before
# they are mirrored outward. Dispatches resolve-failures.yml for any red repos,
# waits for it to finish, then re-checks. Exits non-zero if repos are still
# failing after the resolver runs.
#
# Required env vars:
#   GH_TOKEN       — PAT with repo + actions:write scope (SYNC_TOKEN)
#   REPO           — owner/repo of fork-sync-all (for dispatch-and-wait)
#
# Optional env vars:
#   DRY_RUN        — "true" to report without dispatching resolver (default: false)
#   REPO_FILTER    — substring filter on repo name (default: all)
#   BLOCK_ON_FAIL  — "true" to exit 1 if repos still red after resolver (default: true)
#   BUDGET_MINUTES — time budget in minutes (default: 55)
#   MIN_QUOTA      — skip if quota below this (default: 800)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
BLOCK_ON_FAIL="${BLOCK_ON_FAIL:-true}"
MIN_QUOTA="${MIN_QUOTA:-800}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"
source "${SCRIPT_DIR}/includes/quota-instrument.sh"

budget_init

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[pre-mirror-ci-gate] $*" >&2; }
warn() { echo "[pre-mirror-ci-gate] ⚠️  $*" >&2; }
ok()   { echo "[pre-mirror-ci-gate] ✓ $*" >&2; }
fail() { echo "[pre-mirror-ci-gate] ✗ $*" >&2; }

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota_remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo 0)

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — skipping pre-mirror CI gate."
  exit 0
fi
info "Quota: ${_quota_remaining} remaining"

# ── Load OSP-bound repo list from config ─────────────────────────────────────
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

info "OSP-bound repos to check: ${#OSP_REPOS[@]}"

# ── CI check function ─────────────────────────────────────────────────────────
# Returns a space-separated list of failing repo names (short names only)
check_ci_status() {
  local owner="$1"
  local -a repos=("${@:2}")
  local failing=()

  for repo in "${repos[@]}"; do
    budget_check "$repo" || break
    [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue

    # Get default branch HEAD SHA
    local default_branch sha
    default_branch=$(gh_get "https://api.github.com/repos/${owner}/${repo}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" \
      2>/dev/null || echo "main")
    sha=$(gh_get "https://api.github.com/repos/${owner}/${repo}/commits/${default_branch}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" \
      2>/dev/null || echo "")

    [[ -z "$sha" ]] && continue

    # Check runs
    local check_result
    check_result=$(gh_get \
      "https://api.github.com/repos/${owner}/${repo}/commits/${sha}/check-runs?per_page=100" \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
runs=d.get('check_runs',[])
failing=[r['name'] for r in runs if r.get('conclusion') in ('failure','action_required','timed_out')]
print('FAIL' if failing else 'OK')
" 2>/dev/null || echo "OK")

    if [[ "$check_result" == "FAIL" ]]; then
      warn "  FAIL: ${owner}/${repo}"
      failing+=("$repo")
    else
      ok "  OK:   ${owner}/${repo}"
    fi
  done

  echo "${failing[*]:-}"
}

# ── Pass 1: initial check ─────────────────────────────────────────────────────
info ""
info "Pass 1: checking CI status on I-D-1896 OSP-bound repos..."
qi_begin

FAILING_REPOS=$(check_ci_status "Interested-Deving-1896" "${OSP_REPOS[@]}")
FAILING_COUNT=$(echo "$FAILING_REPOS" | tr ' ' '\n' | grep -c '\S' || true)

qi_end

info ""
info "Pass 1 result: ${FAILING_COUNT} failing repo(s)"

if [[ "$FAILING_COUNT" -eq 0 ]]; then
  ok "All OSP-bound repos are green — safe to mirror."
  exit 0
fi

info "Failing repos: ${FAILING_REPOS}"

# ── Dispatch resolver ─────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY RUN — would dispatch resolve-failures.yml for: ${FAILING_REPOS}"
  [[ "$BLOCK_ON_FAIL" == "true" ]] && exit 1 || exit 0
fi

info ""
info "Dispatching resolve-failures.yml for failing repos..."
REPO_FILTER_ARG="${FAILING_REPOS// /|}"

bash "${SCRIPT_DIR}/dispatch-and-wait.sh" resolve-failures.yml 120 \
  "{\"dry_run\":\"false\",\"repo_filter\":\"${REPO_FILTER_ARG}\",\"scan_owners\":\"Interested-Deving-1896\",\"watchdog_repo\":\"\"}"
rc=$?
if [[ $rc -eq 2 ]]; then
  warn "Resolver was cancelled by queue-manager — proceeding to re-check."
elif [[ $rc -ne 0 ]]; then
  warn "Resolver failed or timed out — proceeding to re-check anyway."
fi

# ── Pass 2: re-check after resolver ──────────────────────────────────────────
info ""
info "Pass 2: re-checking CI status after resolver..."

# Give CI a moment to register new runs
sleep 30

FAILING_REPOS_2=$(check_ci_status "Interested-Deving-1896" "${OSP_REPOS[@]}")
FAILING_COUNT_2=$(echo "$FAILING_REPOS_2" | tr ' ' '\n' | grep -c '\S' || true)

info ""
info "Pass 2 result: ${FAILING_COUNT_2} failing repo(s)"

if [[ "$FAILING_COUNT_2" -eq 0 ]]; then
  ok "All OSP-bound repos are green after resolver — safe to mirror."
  exit 0
fi

warn "Still failing after resolver: ${FAILING_REPOS_2}"

if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
  fail "Blocking mirror — ${FAILING_COUNT_2} repo(s) still red after resolver."
  exit 1
else
  warn "BLOCK_ON_FAIL=false — continuing despite ${FAILING_COUNT_2} failing repo(s)."
  exit 0
fi
