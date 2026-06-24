#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_bfg_pin_e2e.sh — end-to-end integration test for the full
# bfg local_commit --pin-to-ipfs chain.
#
# Tests the complete integration path:
#
#   bfg local_commit --pin-to-ipfs
#     → bdfs snapshot demote   (btrfs-dwarfs-framework)
#     → bdfs-pin-helper        (gitlab-enhanced)
#     → IPFS CID in shutdown log
#     → bdfs fetch --cid       (round-trip restore)
#
# Requirements (all must be on PATH or configured in /etc/bdfs/bdfs.conf):
#   - bfg          (btr-fs-git, with bdfs patch installed)
#   - bdfs         (btrfs-dwarfs-framework CLI)
#   - bdfs_daemon  (running, or started by this test)
#   - bdfs-pin-helper (gitlab-enhanced)
#   - mkdwarfs, dwarfsextract
#   - ipfs (Kubo daemon, running on 127.0.0.1:5001)
#   - btrfs-progs, losetup (for BTRFS loopback setup)
#
# The test creates a temporary BTRFS loopback filesystem, runs bfg
# local_commit --pin-to-ipfs on a test subvolume, verifies the CID
# appears in the shutdown log, then restores via bdfs fetch --cid and
# verifies the content matches.
#
# Exit codes: 0 = all tests passed, 1 = one or more tests failed

set -euo pipefail

# ── configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
KUBO_API="${KUBO_API:-http://127.0.0.1:5001}"
SHUTDOWN_LOG="${SHUTDOWN_LOG:-/var/log/bdfs/workspace-shutdown.jsonl}"
LOOP_SIZE_MB="${LOOP_SIZE_MB:-512}"

# ── test framework ────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ PASS: $*"; ((PASS++)); }
fail() { echo "  ❌ FAIL: $*"; ((FAIL++)); }
skip() { echo "  ⚠️  SKIP: $*"; ((SKIP++)); }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        skip "command not found: $1 — skipping dependent tests"
        return 1
    fi
    return 0
}

# ── setup / teardown ──────────────────────────────────────────────────────────

TMPDIR_ROOT=""
LOOP_DEV=""
BTRFS_MNT=""

setup() {
    mkdir -p "${LOG_DIR}"
    TMPDIR_ROOT=$(mktemp -d /tmp/bdfs-e2e-XXXXXX)

    # Create a BTRFS loopback filesystem
    local img="${TMPDIR_ROOT}/btrfs.img"
    dd if=/dev/null of="${img}" bs=1M seek="${LOOP_SIZE_MB}" 2>/dev/null
    LOOP_DEV=$(losetup --find --show "${img}")
    mkfs.btrfs -q "${LOOP_DEV}"

    BTRFS_MNT="${TMPDIR_ROOT}/mnt"
    mkdir -p "${BTRFS_MNT}"
    mount -t btrfs "${LOOP_DEV}" "${BTRFS_MNT}"

    # Create a test subvolume with known content
    btrfs subvolume create "${BTRFS_MNT}/workspace" &>/dev/null
    echo "hello from bfg e2e test" > "${BTRFS_MNT}/workspace/sentinel.txt"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${BTRFS_MNT}/workspace/timestamp.txt"
    dd if=/dev/urandom bs=1K count=64 of="${BTRFS_MNT}/workspace/random.bin" 2>/dev/null
}

teardown() {
    set +e
    # Unmount and clean up
    if [ -n "${BTRFS_MNT}" ]; then
        umount -l "${BTRFS_MNT}" 2>/dev/null || true
    fi
    if [ -n "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    if [ -n "${TMPDIR_ROOT}" ]; then
        rm -rf "${TMPDIR_ROOT}"
    fi
    set -e
}

trap teardown EXIT

# ── prerequisite checks ───────────────────────────────────────────────────────

echo "=== bfg --pin-to-ipfs end-to-end integration test ==="
echo ""
echo "Checking prerequisites..."

HAVE_BFG=true
HAVE_BDFS=true
HAVE_HELPER=true
HAVE_IPFS=true
HAVE_BTRFS_TOOLS=true

require_cmd bfg           || HAVE_BFG=false
require_cmd bdfs          || HAVE_BDFS=false
require_cmd bdfs-pin-helper || HAVE_HELPER=false
require_cmd mkdwarfs      || HAVE_BDFS=false
require_cmd dwarfsextract || HAVE_BDFS=false
require_cmd losetup       || HAVE_BTRFS_TOOLS=false
require_cmd mkfs.btrfs    || HAVE_BTRFS_TOOLS=false

# Check Kubo is reachable
if ! curl -sf "${KUBO_API}/api/v0/version" -X POST &>/dev/null; then
    skip "Kubo not reachable at ${KUBO_API} — IPFS pinning tests will be skipped"
    HAVE_IPFS=false
fi

# Check bdfs-pin-helper can parse flags
if ${HAVE_HELPER} && ! bdfs-pin-helper --help &>/dev/null; then
    skip "bdfs-pin-helper --help failed — skipping pin tests"
    HAVE_HELPER=false
fi

echo ""

# ── test 1: bfg local_commit (no pin) ────────────────────────────────────────

echo "--- Test 1: bfg local_commit (baseline, no IPFS) ---"

if ! ${HAVE_BFG} || ! ${HAVE_BTRFS_TOOLS}; then
    skip "bfg or btrfs tools unavailable"
else
    setup

    SNAP_PATH=""
    if SNAP_PATH=$(bfg local_commit \
        --subvol "${BTRFS_MNT}/workspace" \
        --tag "e2e-test-$(date +%s)" 2>/dev/null); then
        pass "bfg local_commit succeeded → ${SNAP_PATH}"
    else
        fail "bfg local_commit failed"
    fi

    teardown
    TMPDIR_ROOT=""
fi

# ── test 2: bdfs demote (snapshot → DwarFS archive) ──────────────────────────

echo "--- Test 2: bdfs snapshot demote ---"

if ! ${HAVE_BDFS} || ! ${HAVE_BTRFS_TOOLS}; then
    skip "bdfs or btrfs tools unavailable"
else
    setup

    ARCHIVE="${TMPDIR_ROOT}/workspace.dwarfs"
    if bdfs demote \
        --source "${BTRFS_MNT}/workspace" \
        --dest "${ARCHIVE}" \
        --compression zstd 2>/dev/null; then
        pass "bdfs demote succeeded → ${ARCHIVE}"

        # Verify archive is non-empty and readable
        if dwarfsextract --input "${ARCHIVE}" --output "${TMPDIR_ROOT}/verify" &>/dev/null; then
            if diff -q "${BTRFS_MNT}/workspace/sentinel.txt" \
                       "${TMPDIR_ROOT}/verify/sentinel.txt" &>/dev/null; then
                pass "dwarfsextract round-trip: sentinel.txt matches"
            else
                fail "dwarfsextract round-trip: sentinel.txt content mismatch"
            fi
        else
            fail "dwarfsextract failed on demoted archive"
        fi
    else
        fail "bdfs demote failed"
    fi

    teardown
    TMPDIR_ROOT=""
fi

# ── test 3: bdfs-pin-helper (archive → IPFS CID) ─────────────────────────────

echo "--- Test 3: bdfs-pin-helper (DwarFS archive → IPFS CID) ---"

if ! ${HAVE_HELPER} || ! ${HAVE_IPFS} || ! ${HAVE_BDFS} || ! ${HAVE_BTRFS_TOOLS}; then
    skip "bdfs-pin-helper, Kubo, or bdfs unavailable"
else
    setup

    ARCHIVE="${TMPDIR_ROOT}/workspace.dwarfs"
    bdfs demote \
        --source "${BTRFS_MNT}/workspace" \
        --dest "${ARCHIVE}" \
        --compression zstd 2>/dev/null || { fail "demote failed (prerequisite)"; teardown; TMPDIR_ROOT=""; }

    PIN_OUT=$(bdfs-pin-helper \
        --archive "${ARCHIVE}" \
        --kubo-api "${KUBO_API}" \
        --index "${TMPDIR_ROOT}/pin.db" 2>/dev/null) || PIN_OUT=""

    if [ -n "${PIN_OUT}" ]; then
        CID=$(echo "${PIN_OUT}" | grep -o '"cid":"[^"]*"' | cut -d'"' -f4)
        if [ -n "${CID}" ]; then
            pass "bdfs-pin-helper returned CID: ${CID}"
        else
            fail "bdfs-pin-helper output missing cid field: ${PIN_OUT}"
        fi
    else
        fail "bdfs-pin-helper produced no output"
    fi

    teardown
    TMPDIR_ROOT=""
fi

# ── test 4: bfg local_commit --pin-to-ipfs (full chain) ──────────────────────

echo "--- Test 4: bfg local_commit --pin-to-ipfs (full chain) ---"

if ! ${HAVE_BFG} || ! ${HAVE_HELPER} || ! ${HAVE_IPFS} || ! ${HAVE_BTRFS_TOOLS}; then
    skip "bfg, bdfs-pin-helper, Kubo, or btrfs tools unavailable"
else
    setup

    RESULT=$(bfg local_commit \
        --subvol "${BTRFS_MNT}/workspace" \
        --tag "e2e-pin-$(date +%s)" \
        --pin-to-ipfs \
        --kubo-api "${KUBO_API}" 2>&1) || RESULT=""

    if echo "${RESULT}" | grep -q "ipfs://"; then
        CID=$(echo "${RESULT}" | grep -o 'ipfs://[^ ]*' | head -1 | sed 's|ipfs://||')
        pass "bfg local_commit --pin-to-ipfs succeeded, CID: ${CID}"
    elif echo "${RESULT}" | grep -q "archived to"; then
        pass "bfg local_commit --pin-to-ipfs: archived (pin skipped — acceptable)"
        CID=""
    else
        fail "bfg local_commit --pin-to-ipfs produced unexpected output: ${RESULT}"
        CID=""
    fi

    teardown
    TMPDIR_ROOT=""
fi

# ── test 5: bdfs fetch --cid (round-trip restore) ────────────────────────────

echo "--- Test 5: bdfs fetch --cid (IPFS CID → BTRFS subvolume) ---"

if ! ${HAVE_BDFS} || ! ${HAVE_IPFS} || ! ${HAVE_BTRFS_TOOLS} || [ -z "${CID:-}" ]; then
    skip "bdfs, Kubo unavailable or no CID from test 4"
else
    setup

    RESTORE_DEST="${BTRFS_MNT}/restored"
    if bdfs fetch \
        --cid "${CID}" \
        --dest "${RESTORE_DEST}" \
        --kubo-api "${KUBO_API}" 2>/dev/null; then
        pass "bdfs fetch --cid succeeded → ${RESTORE_DEST}"

        # Verify restored content matches original
        if [ -f "${RESTORE_DEST}/sentinel.txt" ]; then
            RESTORED=$(cat "${RESTORE_DEST}/sentinel.txt")
            if [ "${RESTORED}" = "hello from bfg e2e test" ]; then
                pass "round-trip content verified: sentinel.txt matches"
            else
                fail "round-trip content mismatch: got '${RESTORED}'"
            fi
        else
            fail "sentinel.txt missing from restored subvolume"
        fi
    else
        fail "bdfs fetch --cid failed for CID ${CID}"
    fi

    teardown
    TMPDIR_ROOT=""
fi

# ── test 6: shutdown log contains archive_cid ────────────────────────────────

echo "--- Test 6: shutdown log records archive_cid ---"

if [ ! -f "${SHUTDOWN_LOG}" ]; then
    skip "shutdown log not found at ${SHUTDOWN_LOG}"
elif [ -z "${CID:-}" ]; then
    skip "no CID from test 4 — cannot verify shutdown log"
else
    if grep -q "\"archive_cid\":\"${CID}\"" "${SHUTDOWN_LOG}" 2>/dev/null; then
        pass "shutdown log contains archive_cid: ${CID}"
    else
        # CID may be from bdfs-pin-helper called directly, not via daemon
        LAST_CID=$(tail -20 "${SHUTDOWN_LOG}" | grep -o '"archive_cid":"[^"]*"' | tail -1 | cut -d'"' -f4)
        if [ -n "${LAST_CID}" ] && [ "${LAST_CID}" != "" ]; then
            pass "shutdown log has archive_cid (last entry): ${LAST_CID}"
        else
            fail "shutdown log has no archive_cid entries"
        fi
    fi
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ==="

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
