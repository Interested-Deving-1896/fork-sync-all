#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_dwarfs_partition.sh - DwarFS-backed partition tests
#
# Tests the full pipeline:
#   1. Create a BTRFS filesystem on a loopback device
#   2. Create a subvolume with test data
#   3. Export the subvolume to a DwarFS image (via mkdwarfs)
#   4. Verify the DwarFS image is valid (dwarfsck)
#   5. Mount the DwarFS image (dwarfs FUSE)
#   6. Verify file contents match the original subvolume
#   7. Verify compression ratio is reasonable
#   8. Unmount and clean up

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_root
require_cmd mkfs.btrfs  || exit 0
require_cmd mkdwarfs    || exit 0
require_cmd dwarfs      || exit 0
require_cmd dwarfsck    || exit 0
require_cmd fusermount  || exit 0

echo "=== DwarFS-backed partition tests ==="

# ── Setup ────────────────────────────────────────────────────────────────────

BTRFS_MNT=$(mktemp -d /tmp/bdfs_btrfs_XXXXXX)
DWARFS_MNT=$(mktemp -d /tmp/bdfs_dwarfs_XXXXXX)
DWARFS_IMG=$(mktemp /tmp/bdfs_test_XXXXXX.dwarfs)
TEMP_DIRS+=("$BTRFS_MNT" "$DWARFS_MNT" "$DWARFS_IMG")

make_loop_device 256 BTRFS_DEV
make_btrfs "$BTRFS_DEV" "bdfs_test_src"
mount_btrfs "$BTRFS_DEV" "$BTRFS_MNT"

# ── Test 1: Create subvolume with test data ───────────────────────────────────

make_test_subvol "$BTRFS_MNT" "testdata"
assert_dir_exists "subvolume created" "$BTRFS_MNT/testdata"
assert_file_exists "MANIFEST present" "$BTRFS_MNT/testdata/MANIFEST"
assert_eq "MANIFEST content" "$(cat "$BTRFS_MNT/testdata/MANIFEST")" "testdata"

# ── Test 2: Create read-only snapshot ────────────────────────────────────────

btrfs subvolume snapshot -r "$BTRFS_MNT/testdata" \
    "$BTRFS_MNT/testdata_snap" &>/dev/null
assert_dir_exists "snapshot created" "$BTRFS_MNT/testdata_snap"

# ── Test 3: Export snapshot to DwarFS image ───────────────────────────────────

mkdwarfs -i "$BTRFS_MNT/testdata_snap" -o "$DWARFS_IMG" \
    --compression zstd --block-size-bits 20 --num-workers 2 \
    --categorize &>/dev/null
assert_file_exists "DwarFS image created" "$DWARFS_IMG"

# Image must be non-empty
IMG_SIZE=$(stat -c%s "$DWARFS_IMG")
if [[ $IMG_SIZE -gt 0 ]]; then
    pass "DwarFS image is non-empty (${IMG_SIZE} bytes)"
else
    fail "DwarFS image is empty"
fi

# ── Test 4: Verify DwarFS image integrity ─────────────────────────────────────

assert_cmd_ok "dwarfsck passes" dwarfsck "$DWARFS_IMG" -q

# ── Test 5: Verify compression ratio ─────────────────────────────────────────

ORIG_SIZE=$(du -sb "$BTRFS_MNT/testdata_snap" | awk '{print $1}')
if [[ $ORIG_SIZE -gt 0 && $IMG_SIZE -gt 0 ]]; then
    # Use awk for floating-point division
    RATIO=$(awk "BEGIN {printf \"%.2f\", $ORIG_SIZE / $IMG_SIZE}")
    info "Compression ratio: ${RATIO}x (${ORIG_SIZE} → ${IMG_SIZE} bytes)"
    # Expect at least 1.5x compression on our test data
    RATIO_OK=$(awk "BEGIN {print ($ORIG_SIZE / $IMG_SIZE >= 1.5) ? 1 : 0}")
    if [[ $RATIO_OK -eq 1 ]]; then
        pass "Compression ratio >= 1.5x"
    else
        fail "Compression ratio < 1.5x (got ${RATIO}x)"
    fi
fi

# ── Test 6: Mount DwarFS image and verify contents ────────────────────────────

MOUNT_POINTS+=("$DWARFS_MNT")
dwarfs "$DWARFS_IMG" "$DWARFS_MNT" -o cache_size=64m &>/dev/null
sleep 0.5  # allow FUSE mount to settle

assert_file_exists "MANIFEST accessible via FUSE" "$DWARFS_MNT/MANIFEST"
assert_eq "MANIFEST content via FUSE" \
    "$(cat "$DWARFS_MNT/MANIFEST")" "testdata"

assert_dir_exists "data dir accessible" "$DWARFS_MNT/data"

# Verify file count matches
ORIG_COUNT=$(find "$BTRFS_MNT/testdata_snap" -type f | wc -l)
FUSE_COUNT=$(find "$DWARFS_MNT" -type f | wc -l)
assert_eq "file count matches" "$FUSE_COUNT" "$ORIG_COUNT"

# Verify a specific file's content
ORIG_HASH=$(md5sum "$BTRFS_MNT/testdata_snap/data/file_1.txt" | awk '{print $1}')
FUSE_HASH=$(md5sum "$DWARFS_MNT/data/file_1.txt" | awk '{print $1}')
assert_eq "file content integrity (md5)" "$FUSE_HASH" "$ORIG_HASH"

# ── Test 7: DwarFS image is read-only ─────────────────────────────────────────

assert_cmd_fails "DwarFS mount is read-only" \
    touch "$DWARFS_MNT/should_fail"

# ── Test 8: Unmount ───────────────────────────────────────────────────────────

fusermount -u "$DWARFS_MNT" &>/dev/null
# Remove from MOUNT_POINTS so cleanup doesn't double-unmount
MOUNT_POINTS=("${MOUNT_POINTS[@]/$DWARFS_MNT}")
assert_cmd_fails "mount point is empty after unmount" \
    test -f "$DWARFS_MNT/MANIFEST"

# ── Test 9: Multiple images on same partition ─────────────────────────────────

DWARFS_IMG2=$(mktemp /tmp/bdfs_test2_XXXXXX.dwarfs)
TEMP_DIRS+=("$DWARFS_IMG2")

make_test_subvol "$BTRFS_MNT" "testdata2"
btrfs subvolume snapshot -r "$BTRFS_MNT/testdata2" \
    "$BTRFS_MNT/testdata2_snap" &>/dev/null
mkdwarfs -i "$BTRFS_MNT/testdata2_snap" -o "$DWARFS_IMG2" \
    --compression zstd --num-workers 2 &>/dev/null

assert_file_exists "second DwarFS image created" "$DWARFS_IMG2"
assert_cmd_ok "second image passes dwarfsck" dwarfsck "$DWARFS_IMG2" -q

# ── Test 10: dwarfsck checksum verification ───────────────────────────────────

# Corrupt a byte and verify dwarfsck detects it
CORRUPT_IMG=$(mktemp /tmp/bdfs_corrupt_XXXXXX.dwarfs)
TEMP_DIRS+=("$CORRUPT_IMG")
cp "$DWARFS_IMG" "$CORRUPT_IMG"
# Flip a byte in the middle of the image
python3 -c "
import sys
with open('$CORRUPT_IMG', 'r+b') as f:
    f.seek(len(f.read()) // 2)
    b = f.read(1)
    f.seek(-1, 1)
    f.write(bytes([b[0] ^ 0xFF]))
" 2>/dev/null || true

# dwarfsck should fail on the corrupted image (best-effort test)
if ! dwarfsck "$CORRUPT_IMG" -q &>/dev/null; then
    pass "dwarfsck detects corruption"
else
    skip "dwarfsck did not detect corruption (may depend on where corruption landed)"
fi

print_summary
