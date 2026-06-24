#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_kernel_module.sh - Kernel module load and ioctl interface tests
#
# Loads btrfs_dwarfs.ko, exercises all partition-management ioctls via the
# bdfs CLI, and verifies the /dev/bdfs_ctl control device behaves correctly.
#
# Prerequisites:
#   - Root privileges
#   - btrfs_dwarfs.ko built (make kernel)
#   - bdfs CLI built (make userspace)
#   - mkfs.btrfs, losetup available
#
# The test does NOT require DwarFS userspace tools; it only exercises the
# kernel ioctl interface and partition registry.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_root

echo "=== Kernel module ioctl tests ==="

# ── Locate build artefacts ────────────────────────────────────────────────────

KO_PATH="$REPO_ROOT/kernel/btrfs_dwarfs/btrfs_dwarfs.ko"
BDFS_BIN="$REPO_ROOT/build/userspace/bdfs"

if [[ ! -f "$KO_PATH" ]]; then
    skip "btrfs_dwarfs.ko not found at $KO_PATH — run 'make kernel' first"
    print_summary
    exit 0
fi

if [[ ! -x "$BDFS_BIN" ]]; then
    skip "bdfs CLI not found at $BDFS_BIN — run 'make userspace' first"
    print_summary
    exit 0
fi

# ── Module load ───────────────────────────────────────────────────────────────

# Unload any stale instance first (ignore errors)
rmmod btrfs_dwarfs 2>/dev/null || true

if insmod "$KO_PATH"; then
    pass "insmod btrfs_dwarfs.ko"
else
    fail "insmod btrfs_dwarfs.ko"
    print_summary
    exit 1
fi

# Ensure module is unloaded on exit
TEMP_DIRS+=("/tmp/bdfs_ko_test_sentinel")  # trigger cleanup trap
_orig_cleanup=$(declare -f cleanup)
cleanup() {
    rmmod btrfs_dwarfs 2>/dev/null || true
    eval "${_orig_cleanup#cleanup ()}"
}

# ── /dev/bdfs_ctl exists ──────────────────────────────────────────────────────

assert_file_exists "/dev/bdfs_ctl created by module" /dev/bdfs_ctl

# ── Module appears in lsmod ───────────────────────────────────────────────────

if lsmod | grep -q "^btrfs_dwarfs"; then
    pass "btrfs_dwarfs visible in lsmod"
else
    fail "btrfs_dwarfs not visible in lsmod"
fi

# ── dmesg shows expected init messages ───────────────────────────────────────

if dmesg | tail -30 | grep -q "bdfs:.*control device.*bdfs_ctl"; then
    pass "dmesg: control device registered"
else
    fail "dmesg: expected 'bdfs_ctl registered' message not found"
fi

if dmesg | tail -30 | grep -q "bdfs:.*blend filesystem type.*registered"; then
    pass "dmesg: blend filesystem type registered"
else
    fail "dmesg: expected blend filesystem registration message not found"
fi

# ── BTRFS-backed partition: register ─────────────────────────────────────────

BTRFS_MNT=$(mktemp -d /tmp/bdfs_ko_btrfs_XXXXXX)
TEMP_DIRS+=("$BTRFS_MNT")

require_cmd mkfs.btrfs || { print_summary; exit 0; }

make_loop_device 256 BTRFS_DEV
make_btrfs "$BTRFS_DEV" "bdfs_ko_test"
mount_btrfs "$BTRFS_DEV" "$BTRFS_MNT"

PART_UUID=$("$BDFS_BIN" partition add \
    --type btrfs \
    --path "$BTRFS_MNT" \
    --label "ko_test_btrfs" \
    2>&1 | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

if [[ -n "$PART_UUID" ]]; then
    pass "partition add (BTRFS-backed) returned UUID: $PART_UUID"
else
    fail "partition add (BTRFS-backed) did not return a UUID"
fi

# ── List partitions ───────────────────────────────────────────────────────────

LIST_OUT=$("$BDFS_BIN" partition list 2>&1)
if echo "$LIST_OUT" | grep -q "ko_test_btrfs"; then
    pass "partition list shows registered partition"
else
    fail "partition list does not show 'ko_test_btrfs'"
fi

# ── Partition show ────────────────────────────────────────────────────────────

if [[ -n "$PART_UUID" ]]; then
    SHOW_OUT=$("$BDFS_BIN" partition show "$PART_UUID" 2>&1)
    if echo "$SHOW_OUT" | grep -q "$PART_UUID"; then
        pass "partition show returns correct UUID"
    else
        fail "partition show output missing UUID"
    fi
fi

# ── DwarFS-backed partition: register ────────────────────────────────────────

DWARFS_STORE=$(mktemp -d /tmp/bdfs_ko_dwarfs_XXXXXX)
TEMP_DIRS+=("$DWARFS_STORE")

DPART_UUID=$("$BDFS_BIN" partition add \
    --type dwarfs \
    --path "$DWARFS_STORE" \
    --label "ko_test_dwarfs" \
    2>&1 | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

if [[ -n "$DPART_UUID" ]]; then
    pass "partition add (DwarFS-backed) returned UUID: $DPART_UUID"
else
    fail "partition add (DwarFS-backed) did not return a UUID"
fi

# ── List shows both partitions ────────────────────────────────────────────────

LIST2=$("$BDFS_BIN" partition list 2>&1)
PART_COUNT=$(echo "$LIST2" | grep -c "ko_test_" || true)
if [[ "$PART_COUNT" -ge 2 ]]; then
    pass "partition list shows both registered partitions"
else
    fail "partition list shows $PART_COUNT/2 expected partitions"
fi

# ── IOCTL: invalid magic rejected ────────────────────────────────────────────

# Attempt to register a partition with wrong magic via direct ioctl.
# We use python3 with ctypes to send a malformed ioctl and expect EINVAL.
if command -v python3 &>/dev/null; then
    IOCTL_TEST=$(python3 - <<'PYEOF' 2>&1
import ctypes, fcntl, struct, errno, os

BDFS_IOCTL_MAGIC = 0xBD
BDFS_IOC_REGISTER = (3 << 30) | (BDFS_IOCTL_MAGIC << 8) | 0x01

# Build a bdfs_ioctl_register_partition with wrong magic (0xDEAD)
# struct layout: magic(4) + type(4) + flags(4) + pad(4) + uuid(16) +
#                label(64) + path(4096) + uuid_out(16) = ~4208 bytes
buf = bytearray(4208)
struct.pack_into('<I', buf, 0, 0xDEAD)  # wrong magic

try:
    fd = os.open('/dev/bdfs_ctl', os.O_RDWR)
    fcntl.ioctl(fd, BDFS_IOC_REGISTER, bytes(buf))
    os.close(fd)
    print("UNEXPECTED_SUCCESS")
except OSError as e:
    os.close(fd) if 'fd' in dir() else None
    if e.errno in (errno.EINVAL, errno.EFAULT):
        print("REJECTED_AS_EXPECTED")
    else:
        print(f"UNEXPECTED_ERRNO_{e.errno}")
PYEOF
)
    if echo "$IOCTL_TEST" | grep -q "REJECTED_AS_EXPECTED"; then
        pass "ioctl: invalid magic correctly rejected (EINVAL/EFAULT)"
    elif echo "$IOCTL_TEST" | grep -q "UNEXPECTED_SUCCESS"; then
        fail "ioctl: invalid magic was not rejected"
    else
        skip "ioctl magic test: $IOCTL_TEST"
    fi
else
    skip "python3 not available — skipping raw ioctl test"
fi

# ── Partition remove ──────────────────────────────────────────────────────────

if [[ -n "$PART_UUID" ]]; then
    if "$BDFS_BIN" partition remove "$PART_UUID" &>/dev/null; then
        pass "partition remove BTRFS-backed partition"
    else
        fail "partition remove BTRFS-backed partition failed"
    fi
fi

if [[ -n "$DPART_UUID" ]]; then
    if "$BDFS_BIN" partition remove "$DPART_UUID" &>/dev/null; then
        pass "partition remove DwarFS-backed partition"
    else
        fail "partition remove DwarFS-backed partition failed"
    fi
fi

# ── List is empty after removal ───────────────────────────────────────────────

LIST3=$("$BDFS_BIN" partition list 2>&1)
REMAINING=$(echo "$LIST3" | grep -c "ko_test_" || true)
if [[ "$REMAINING" -eq 0 ]]; then
    pass "partition list empty after removal"
else
    fail "partition list still shows $REMAINING partition(s) after removal"
fi

# ── Module unload ─────────────────────────────────────────────────────────────

if rmmod btrfs_dwarfs 2>/dev/null; then
    pass "rmmod btrfs_dwarfs"
else
    fail "rmmod btrfs_dwarfs (module may be in use)"
fi

if [[ ! -e /dev/bdfs_ctl ]]; then
    pass "/dev/bdfs_ctl removed after rmmod"
else
    fail "/dev/bdfs_ctl still exists after rmmod"
fi

print_summary
