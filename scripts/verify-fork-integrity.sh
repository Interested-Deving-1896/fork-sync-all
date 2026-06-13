#!/usr/bin/env bash
#
# verify-fork-integrity.sh
#
# Compares the default-branch HEAD SHA of this repo against its upstream
# (fork parent or explicit UPSTREAM_REPO override). Reports whether the fork
# is in sync, behind, ahead, or diverged.
#
# Designed for consumer repos that receive the infra-core template profile.
# Runs in the consumer repo itself — no org-wide sweep, no OSP-bound list.
#
# Required env vars:
#   GH_TOKEN        — PAT with repo read scope
#   FORK_REPO       — full path of the fork to check (owner/name)
#
# Optional env vars:
#   UPSTREAM_REPO   — explicit upstream (owner/name). If blank, resolved from
#                     the GitHub fork parent API field.
#   BLOCK_ON_DRIFT  — "true" to exit 1 when fork is behind or diverged (default: false)
#   BUDGET_MINUTES  — time budget in minutes (default: 5)
#   MIN_QUOTA       — skip if quota below this (default: 100)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${FORK_REPO:?FORK_REPO is required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-}"
BLOCK_ON_DRIFT="${BLOCK_ON_DRIFT:-false}"
MIN_QUOTA="${MIN_QUOTA:-100}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"
budget_init

API="https://api.github.com"

info()  { echo "[verify-fork-integrity] $*" >&2; }
warn()  { echo "[verify-fork-integrity] ⚠️  $*" >&2; }
ok()    { echo "[verify-fork-integrity] ✓ $*" >&2; }
fail()  { echo "[verify-fork-integrity] ✗ $*" >&2; }

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "${API}/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo 0)

if (( _quota < MIN_QUOTA )); then
  warn "Quota too low (${_quota} < ${MIN_QUOTA}) — skipping integrity check."
  exit 0
fi
info "Quota: ${_quota} remaining"

# ── Resolve upstream ──────────────────────────────────────────────────────────
if [[ -z "$UPSTREAM_REPO" ]]; then
  info "Resolving upstream from fork parent API..."
  fork_meta=$(gh_get "${API}/repos/${FORK_REPO}") || {
    warn "Could not fetch repo metadata for ${FORK_REPO}"
    exit 0
  }

  is_fork=$(echo "$fork_meta" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('fork', False))" 2>/dev/null || echo "False")

  if [[ "$is_fork" != "True" ]]; then
    info "${FORK_REPO} is not a fork — no upstream to compare against."
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "## Fork Integrity: ${FORK_REPO}" >> "$GITHUB_STEP_SUMMARY"
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "ℹ️ This repo is not a fork — no upstream comparison possible." >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi

  UPSTREAM_REPO=$(echo "$fork_meta" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('parent',{}).get('full_name',''))" \
    2>/dev/null || echo "")

  if [[ -z "$UPSTREAM_REPO" ]]; then
    warn "Could not resolve upstream parent for ${FORK_REPO}"
    exit 0
  fi
fi

info "Fork:     ${FORK_REPO}"
info "Upstream: ${UPSTREAM_REPO}"

# ── Resolve default branches ──────────────────────────────────────────────────
fork_meta="${fork_meta:-$(gh_get "${API}/repos/${FORK_REPO}" || echo '{}')}"
fork_branch=$(echo "$fork_meta" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

upstream_meta=$(gh_get "${API}/repos/${UPSTREAM_REPO}") || {
  warn "Could not fetch upstream metadata for ${UPSTREAM_REPO}"
  exit 0
}
upstream_branch=$(echo "$upstream_meta" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

info "Fork branch:     ${fork_branch}"
info "Upstream branch: ${upstream_branch}"

# ── Fetch HEAD SHAs ───────────────────────────────────────────────────────────
fork_sha=$(gh_get "${API}/repos/${FORK_REPO}/commits/${fork_branch}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

upstream_sha=$(gh_get "${API}/repos/${UPSTREAM_REPO}/commits/${upstream_branch}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

if [[ -z "$fork_sha" ]]; then
  warn "Could not resolve HEAD SHA for fork ${FORK_REPO}@${fork_branch}"
  exit 0
fi
if [[ -z "$upstream_sha" ]]; then
  warn "Could not resolve HEAD SHA for upstream ${UPSTREAM_REPO}@${upstream_branch}"
  exit 0
fi

fork_short="${fork_sha:0:12}"
upstream_short="${upstream_sha:0:12}"

info "Fork SHA:     ${fork_short}"
info "Upstream SHA: ${upstream_short}"

# ── Compare via merge-base ────────────────────────────────────────────────────
# Use the compare API to determine relationship: ahead/behind/diverged/identical
compare=$(gh_get "${API}/repos/${UPSTREAM_REPO}/compare/${upstream_sha}...${fork_sha}") || {
  warn "Could not compare SHAs — reporting raw SHA diff only"
  compare="{}"
}

status=$(echo "$compare" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
ahead_by=$(echo "$compare" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('ahead_by',0))" 2>/dev/null || echo 0)
behind_by=$(echo "$compare" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('behind_by',0))" 2>/dev/null || echo 0)

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
case "$status" in
  identical)
    ok "IN SYNC: ${FORK_REPO} matches upstream ${UPSTREAM_REPO} (${fork_short})"
    DRIFT=false
    ;;
  ahead)
    ok "AHEAD: ${FORK_REPO} is ${ahead_by} commit(s) ahead of upstream — no action needed"
    DRIFT=false
    ;;
  behind)
    warn "BEHIND: ${FORK_REPO} is ${behind_by} commit(s) behind upstream ${UPSTREAM_REPO}"
    warn "  Fork:     ${fork_short}"
    warn "  Upstream: ${upstream_short}"
    DRIFT=true
    ;;
  diverged)
    warn "DIVERGED: ${FORK_REPO} has diverged from upstream ${UPSTREAM_REPO}"
    warn "  Fork:     ${fork_short} (+${ahead_by})"
    warn "  Upstream: ${upstream_short} (+${behind_by})"
    DRIFT=true
    ;;
  *)
    warn "UNKNOWN status '${status}' — fork=${fork_short} upstream=${upstream_short}"
    DRIFT=false
    ;;
esac

# ── Step summary ──────────────────────────────────────────────────────────────
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Fork Integrity: ${FORK_REPO}"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Fork | \`${FORK_REPO}\` @ \`${fork_short}\` |"
    echo "| Upstream | \`${UPSTREAM_REPO}\` @ \`${upstream_short}\` |"
    echo "| Status | ${status} |"
    [[ "$ahead_by" -gt 0 ]]  && echo "| Ahead by | ${ahead_by} commit(s) |"
    [[ "$behind_by" -gt 0 ]] && echo "| Behind by | ${behind_by} commit(s) |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

budget_report

if [[ "$BLOCK_ON_DRIFT" == "true" && "$DRIFT" == "true" ]]; then
  fail "Blocking: fork is ${status} relative to upstream."
  exit 1
fi

exit 0
