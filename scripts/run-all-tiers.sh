#!/usr/bin/env bash
# Master orchestration: audit → Tier 1 → Tier 2 → Tier 3 → push content → seed branches.
# Safe to re-run — all steps skip already-completed work.
#
# Usage:
#   export GH_TOKEN=ghp_...
#   ./run-all-tiers.sh
#   ./run-all-tiers.sh --skip-audit       # skip repo audit
#   ./run-all-tiers.sh --start-at tier2   # resume from a specific tier
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

START_AT="audit"
SKIP_AUDIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-audit) SKIP_AUDIT=true; shift ;;
    --start-at) START_AT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

check_rate_limit() {
  local remaining
  remaining=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/rate_limit" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo 0)
  echo "$remaining"
}

wait_for_rate_limit() {
  local min_calls="${1:-200}"
  while true; do
    local remaining
    remaining=$(check_rate_limit)
    if [[ "$remaining" -ge "$min_calls" ]]; then
      log "Rate limit OK: ${remaining} remaining"
      return 0
    fi
    local reset
    reset=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/rate_limit" | python3 -c \
      "import json,sys,time; d=json.load(sys.stdin); r=d['resources']['core']['reset']; print(max(0,r-int(time.time()))+10)" 2>/dev/null || echo 60)
    log "Rate limited (${remaining} remaining). Waiting ${reset}s..."
    sleep "$reset"
  done
}

log "=== Master orchestration started ==="
log "Kernel clone: $(du -sh /workspaces/linux-kernel 2>/dev/null | cut -f1 || echo 'not ready')"

# ── Audit ──────────────────────────────────────────────────────────────────
if [[ "$START_AT" == "audit" ]] && ! $SKIP_AUDIT; then
  log "Step 1/6: Audit existing repos"
  wait_for_rate_limit 10
  bash "$SCRIPT_DIR/audit-arch-repos.sh"
fi

# ── Tier 1: arm64 ─────────────────────────────────────────────────────────
if [[ "$START_AT" =~ ^(audit|tier1)$ ]]; then
  log "Step 2/6: Tier 1 — arm64"
  wait_for_rate_limit 100
  bash "$SCRIPT_DIR/run-tier1-arm64.sh"
fi

# ── Tier 2: armhf + riscv64 + s390x ───────────────────────────────────────
if [[ "$START_AT" =~ ^(audit|tier1|tier2)$ ]]; then
  log "Step 3/6: Tier 2 — armhf + riscv64 + s390x"
  wait_for_rate_limit 200
  bash "$SCRIPT_DIR/run-tier2.sh"
fi

# ── Tier 3: armel + ppc64el + mips64el + loong64 + i686 ───────────────────
if [[ "$START_AT" =~ ^(audit|tier1|tier2|tier3)$ ]]; then
  log "Step 4/6: Tier 3 — armel + ppc64el + mips64el + loong64 + i686"
  wait_for_rate_limit 300
  bash "$SCRIPT_DIR/run-tier3.sh"
fi

# ── Push kernel content ────────────────────────────────────────────────────
log "Step 5/6: Push kernel content to kernel-base repos"
if [[ ! -d "/workspaces/linux-kernel/.git" ]]; then
  log "Waiting for kernel clone to finish..."
  while [[ ! -f "/workspaces/linux-kernel/.git/FETCH_HEAD" ]] && \
        [[ ! -f "/workspaces/linux-kernel/.git/packed-refs" ]]; do
    sleep 10
    log "  clone still running... ($(du -sh /workspaces/linux-kernel 2>/dev/null | cut -f1))"
  done
fi
bash "$SCRIPT_DIR/push-kernel-content.sh"

# ── Seed patchset branches ─────────────────────────────────────────────────
log "Step 6/6: Seed patchset branches"
bash "$SCRIPT_DIR/seed-patchset-branches.sh"

log "=== All done ==="
