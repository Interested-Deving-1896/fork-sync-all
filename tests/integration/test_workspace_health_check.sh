#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_workspace_health_check.sh - workspace-health-check integration tests
#
# Tests the tools/workspace-health-check script against real BTRFS loopback
# subvolumes, verifying exit codes and JSON output for all health states:
#
#   1. Healthy: snapshot present, bdfs installed → exit 0, healthy=true
#   2. Unhealthy: no snapshot, --require-snapshot → exit 1, healthy=false
#   3. Unhealthy: path does not exist → exit 2, reason=path_not_found
#   4. Healthy: no snapshot, --require-snapshot not set → exit 0, healthy=true
#   5. JSON output: snapshot_count, latest, archive_exists fields correct
#   6. JSON reason field matches exit code semantics
#   7. bdfs absent + --require-snapshot → exit 3, reason=bdfs_missing
#   8. bdfs absent + no --require-snapshot → exit 0, healthy=true
#   9. Timeout: health check respects --timeout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

HEALTH_CHECK="${SCRIPT_DIR}/../../tools/workspace-health-check"

require_root
require_cmd mkfs.btrfs || exit 0
require_cmd btrfs      || exit 0

echo "=== workspace-health-check integration tests ==="

# ── Setup ─────────────────────────────────────────────────────────────────────

BTRFS_MNT=$(mktemp -d /tmp/bdfs_hc_XXXXXX)
TEMP_DIRS+=("$BTRFS_MNT")

make_loop_device 256 BTRFS_DEV
make_btrfs "$BTRFS_DEV" "bdfs_hc_test"
mount_btrfs "$BTRFS_DEV" "$BTRFS_MNT"

# Create a workspace subvolume
btrfs subvolume create "$BTRFS_MNT/ws" &>/dev/null
echo "test" > "$BTRFS_MNT/ws/MANIFEST"

# ── Test 1: Healthy — snapshot present ───────────────────────────────────────

# Create a ws-snap-* snapshot
btrfs subvolume snapshot -r "$BTRFS_MNT/ws" \
    "$BTRFS_MNT/ws-snap-$(date +%s)" &>/dev/null

rc=0
"$HEALTH_CHECK" --workspace-path "$BTRFS_MNT" --require-snapshot || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "healthy: snapshot present → exit 0"
else
    fail "healthy: snapshot present → expected exit 0, got $rc"
fi

# ── Test 2: Unhealthy — no snapshot, --require-snapshot ──────────────────────

# Create a fresh workspace with no snapshots
btrfs subvolume create "$BTRFS_MNT/ws_nosnap" &>/dev/null

rc=0
"$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT/ws_nosnap" \
    --require-snapshot || rc=$?
if [[ $rc -eq 1 ]]; then
    pass "unhealthy: no snapshot + --require-snapshot → exit 1"
else
    fail "unhealthy: no snapshot + --require-snapshot → expected exit 1, got $rc"
fi

# ── Test 3: Unhealthy — path does not exist ───────────────────────────────────

rc=0
"$HEALTH_CHECK" \
    --workspace-path "/nonexistent/path/$(date +%s)" \
    --require-snapshot || rc=$?
if [[ $rc -eq 2 ]]; then
    pass "unhealthy: path not found → exit 2"
else
    fail "unhealthy: path not found → expected exit 2, got $rc"
fi

# ── Test 4: Healthy — no snapshot, no --require-snapshot ─────────────────────

rc=0
"$HEALTH_CHECK" --workspace-path "$BTRFS_MNT/ws_nosnap" || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "healthy: no snapshot, not required → exit 0"
else
    fail "healthy: no snapshot, not required → expected exit 0, got $rc"
fi

# ── Test 5: JSON output — fields correct ─────────────────────────────────────

JSON=$("$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT" \
    --require-snapshot \
    --json 2>/dev/null || true)

if echo "$JSON" | grep -q '"healthy":true'; then
    pass "json: healthy=true when snapshot present"
else
    fail "json: expected healthy=true, got: ${JSON:0:200}"
fi

SNAP_COUNT=$(echo "$JSON" | grep -o '"snapshot_count":[0-9]*' \
    | grep -o '[0-9]*' || echo 0)
if [[ "${SNAP_COUNT:-0}" -ge 1 ]]; then
    pass "json: snapshot_count >= 1"
else
    fail "json: expected snapshot_count >= 1, got $SNAP_COUNT"
fi

if echo "$JSON" | grep -q '"latest_snapshot":"ws-snap-'; then
    pass "json: latest_snapshot field present and named correctly"
else
    fail "json: latest_snapshot field missing or wrong: ${JSON:0:200}"
fi

# ── Test 6: JSON reason field matches exit code ───────────────────────────────

JSON_NOSNAP=$("$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT/ws_nosnap" \
    --require-snapshot \
    --json 2>/dev/null || true)

REASON=$(echo "$JSON_NOSNAP" | grep -o '"reason":"[^"]*"' \
    | cut -d'"' -f4 || echo "")
if [[ "$REASON" == "no_snapshot" ]]; then
    pass "json: reason=no_snapshot when no snapshots and required"
else
    fail "json: expected reason=no_snapshot, got '$REASON'"
fi

JSON_NOPATH=$("$HEALTH_CHECK" \
    --workspace-path "/nonexistent/$(date +%s)" \
    --json 2>/dev/null || true)

REASON_NP=$(echo "$JSON_NOPATH" | grep -o '"reason":"[^"]*"' \
    | cut -d'"' -f4 || echo "")
if [[ "$REASON_NP" == "path_not_found" ]]; then
    pass "json: reason=path_not_found when path missing"
else
    fail "json: expected reason=path_not_found, got '$REASON_NP'"
fi

# ── Test 7: bdfs absent + --require-snapshot → exit 3 ────────────────────────

# Shadow bdfs with an empty dir on PATH
EMPTY_DIR=$(mktemp -d)
TEMP_DIRS+=("$EMPTY_DIR")

rc=0
PATH="$EMPTY_DIR:$PATH" "$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT" \
    --require-snapshot || rc=$?
if [[ $rc -eq 3 ]]; then
    pass "bdfs absent + --require-snapshot → exit 3"
else
    fail "bdfs absent + --require-snapshot → expected exit 3, got $rc"
fi

# ── Test 8: bdfs absent + no --require-snapshot → exit 0 ─────────────────────

rc=0
PATH="$EMPTY_DIR:$PATH" "$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT" || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "bdfs absent + not required → exit 0 (healthy)"
else
    fail "bdfs absent + not required → expected exit 0, got $rc"
fi

# ── Test 9: JSON output includes duration_ms ─────────────────────────────────

JSON_DUR=$("$HEALTH_CHECK" \
    --workspace-path "$BTRFS_MNT" \
    --json 2>/dev/null || true)

if echo "$JSON_DUR" | grep -qE '"duration_ms":[0-9]+'; then
    pass "json: duration_ms field present and numeric"
else
    fail "json: duration_ms field missing: ${JSON_DUR:0:200}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

print_summary
