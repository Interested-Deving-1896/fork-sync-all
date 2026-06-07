#!/usr/bin/env bash
# Full local orchestration: wait for rate limit → audit → all tiers →
# push kernel content → seed branches.
# Logs to /tmp/run-everything.log
#
# Usage:
#   export GH_TOKEN=ghp_...
#   bash scripts/run-everything.sh
set -euo pipefail

LOG="/tmp/run-everything.log"
exec > >(tee -a "$LOG") 2>&1

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

# ── Rate limit helpers ─────────────────────────────────────────────────────

rate_remaining() {
  curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/rate_limit" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" \
    2>/dev/null || echo 0
}

rate_reset() {
  curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/rate_limit" | \
    python3 -c "import json,sys,time; d=json.load(sys.stdin); r=d['resources']['core']['reset']; print(max(0,r-int(time.time()))+5)" \
    2>/dev/null || echo 60
}

wait_for_rate_limit() {
  local min="${1:-200}"
  while true; do
    local rem
    rem=$(rate_remaining)
    if [[ "$rem" -ge "$min" ]]; then
      log "Rate limit OK: ${rem} remaining"
      return 0
    fi
    local wait
    wait=$(rate_reset)
    log "Rate limited (${rem} remaining). Sleeping ${wait}s..."
    sleep "$wait"
  done
}

# ── Step 1: Wait for rate limit ────────────────────────────────────────────
log "=== Waiting for rate limit reset ==="
wait_for_rate_limit 500

# ── Step 2: Audit ─────────────────────────────────────────────────────────
log "=== Step 1/5: Audit existing repos ==="
bash "$SCRIPT_DIR/audit-arch-repos.sh"

# ── Step 3: Tier 1 — arm64 ────────────────────────────────────────────────
log "=== Step 2/5: Tier 1 — arm64 ==="
wait_for_rate_limit 100
bash "$SCRIPT_DIR/run-tier1-arm64.sh"

# ── Step 4: Tier 2 — armhf + riscv64 + s390x ──────────────────────────────
log "=== Step 3/5: Tier 2 — armhf + riscv64 + s390x ==="
wait_for_rate_limit 200
bash "$SCRIPT_DIR/run-tier2.sh"

# ── Step 5: Tier 3 — armel + ppc64el + mips64el + loong64 + i686 ──────────
log "=== Step 4/5: Tier 3 — armel + ppc64el + mips64el + loong64 + i686 ==="
wait_for_rate_limit 300
bash "$SCRIPT_DIR/run-tier3.sh"

# ── Step 6: Push kernel content ───────────────────────────────────────────
log "=== Step 5/5: Push kernel content ==="
if [[ ! -d "/workspaces/linux-kernel/.git" ]]; then
  log "ERROR: kernel not cloned at /workspaces/linux-kernel" >&2
  exit 1
fi
bash "$SCRIPT_DIR/push-kernel-content.sh"

log "=== All done ==="
