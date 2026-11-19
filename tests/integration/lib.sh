#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/integration/lib.sh - Shared helpers for integration tests
#
# Each test script sources this file.  Tests run as root against loopback
# devices so no real block devices are needed.

set -euo pipefail

# ── Colour output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0

pass() { echo -e "${GREEN}PASS${NC} $*"; ((PASS++)); }
fail() { echo -e "${RED}FAIL${NC} $*"; ((FAIL++)); }
skip() { echo -e "${YELLOW}SKIP${NC} $*"; ((SKIP++)); }
info() { echo -e "     $*"; }

# ── Prerequisite checks ──────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Integration tests must run as root (need loopback + mount)."
        exit 1
    fi
}

require_cmd() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        skip "prerequisite '$cmd' not found — skipping test"
        return 1
    fi
    return 0
}

require_module() {
    local mod=$1
    if ! lsmod | grep -q "^${mod}"; then
        if ! modprobe "$mod" 2>/dev/null; then
            skip "kernel module '$mod' not available — skipping test"
            return 1
        fi
    fi
    return 0
}

# ── Loopback device helpers ──────────────────────────────────────────────────

LOOP_DEVICES=()
MOUNT_POINTS=()
TEMP_DIRS=()

# Create a loopback-backed sparse image and return the loop device path.
# Usage: make_loop_device <size_mb> <var_name>
make_loop_device() {
    local size_mb=$1
    local var=$2
    local img
    img=$(mktemp /tmp/bdfs_test_XXXXXX.img)
    TEMP_DIRS+=("$img")
    truncate -s "${size_mb}M" "$img"
    local dev
    dev=$(losetup --find --show "$img")
    LOOP_DEVICES+=("$dev")
    eval "$var=$dev"
}

# Format a loop device as BTRFS.
# Usage: make_btrfs <device> <label>
make_btrfs() {
    local dev=$1 label=${2:-bdfs_test}
    mkfs.btrfs -f -L "$label" "$dev" &>/dev/null
}

# Mount a BTRFS device.
# Usage: mount_btrfs <device> <mountpoint>
mount_btrfs() {
    local dev=$1 mnt=$2
    mkdir -p "$mnt"
    mount -t btrfs "$dev" "$mnt"
    MOUNT_POINTS+=("$mnt")
}

# Create a BTRFS subvolume and populate it with test data.
# Usage: make_test_subvol <btrfs_mount> <subvol_name>
make_test_subvol() {
    local mnt=$1 name=$2
    btrfs subvolume create "$mnt/$name" &>/dev/null
    # Populate with varied data to exercise DwarFS compression
    mkdir -p "$mnt/$name/bin" "$mnt/$name/lib" "$mnt/$name/data"
    # Compressible text files
    for i in $(seq 1 20); do
        printf 'Hello from bdfs test file %d\n%.0s' {1..500} \
            > "$mnt/$name/data/file_$i.txt"
    done
    # Binary-ish data
    dd if=/dev/urandom bs=4096 count=8 \
        of="$mnt/$name/data/random.bin" 2>/dev/null
    # Duplicate files (DwarFS deduplication target)
    cp "$mnt/$name/data/file_1.txt" "$mnt/$name/data/file_dup.txt"
    echo "$name" > "$mnt/$name/MANIFEST"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    local rc=$?
    # Unmount in reverse order
    local i
    for (( i=${#MOUNT_POINTS[@]}-1; i>=0; i-- )); do
        umount -l "${MOUNT_POINTS[$i]}" 2>/dev/null || true
    done
    # Detach loop devices
    for dev in "${LOOP_DEVICES[@]}"; do
        losetup -d "$dev" 2>/dev/null || true
    done
    # Remove temp files/dirs
    for f in "${TEMP_DIRS[@]}"; do
        rm -rf "$f" 2>/dev/null || true
    done
    return $rc
}
trap cleanup EXIT

# ── Assertion helpers ────────────────────────────────────────────────────────

assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        pass "$desc"
    else
        fail "$desc (got='$got' want='$want')"
    fi
}

assert_file_exists() {
    local desc=$1 path=$2
    if [[ -e "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file not found: $path)"
    fi
}

assert_dir_exists() {
    local desc=$1 path=$2
    if [[ -d "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (directory not found: $path)"
    fi
}

assert_cmd_ok() {
    local desc=$1; shift
    if "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (command failed: $*)"
    fi
}

assert_cmd_fails() {
    local desc=$1; shift
    if ! "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (expected failure but succeeded: $*)"
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    local total=$(( PASS + FAIL + SKIP ))
    echo ""
    echo "Results: ${total} tests — ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
    [[ $FAIL -eq 0 ]]
}
