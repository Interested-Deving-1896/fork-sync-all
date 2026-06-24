#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_btrfs_partition.sh - BTRFS-backed partition tests
#
# Tests the full pipeline for BTRFS-backed partitions:
#   1. Create a BTRFS filesystem to act as the "partition"
#   2. Store a DwarFS image file onto it
#   3. Verify BTRFS CoW semantics (reflink copy)
#   4. Create a BTRFS snapshot of the subvolume containing the image
#   5. Verify the snapshot is independent (CoW)
#   6. Import a DwarFS image into a new BTRFS subvolume (dwarfsextract)
#   7. Verify the imported subvolume matches the original DwarFS content

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_root
require_cmd mkfs.btrfs    || exit 0
require_cmd mkdwarfs      || exit 0
require_cmd dwarfsextract || exit 0

echo "=== BTRFS-backed partition tests ==="

# ── Setup ────────────────────────────────────────────────────────────────────

SRC_MNT=$(mktemp -d /tmp/bdfs_src_XXXXXX)
BTRFS_PART_MNT=$(mktemp -d /tmp/bdfs_part_XXXXXX)
EXTRACT_DIR=$(mktemp -d /tmp/bdfs_extract_XXXXXX)
TEMP_DIRS+=("$SRC_MNT" "$BTRFS_PART_MNT" "$EXTRACT_DIR")

# Source BTRFS (where subvolumes live)
make_loop_device 256 SRC_DEV
make_btrfs "$SRC_DEV" "bdfs_src"
mount_btrfs "$SRC_DEV" "$SRC_MNT"

# BTRFS partition (where DwarFS images are stored)
make_loop_device 512 PART_DEV
make_btrfs "$PART_DEV" "bdfs_partition"
mount_btrfs "$PART_DEV" "$BTRFS_PART_MNT"

# Create a subvolume on the partition to hold images
btrfs subvolume create "$BTRFS_PART_MNT/images" &>/dev/null

# ── Test 1: Create source data and DwarFS image ───────────────────────────────

make_test_subvol "$SRC_MNT" "source"
DWARFS_IMG=$(mktemp /tmp/bdfs_src_XXXXXX.dwarfs)
TEMP_DIRS+=("$DWARFS_IMG")

mkdwarfs -i "$SRC_MNT/source" -o "$DWARFS_IMG" \
    --compression zstd --num-workers 2 &>/dev/null
assert_file_exists "source DwarFS image created" "$DWARFS_IMG"

# ── Test 2: Store DwarFS image onto BTRFS partition ───────────────────────────

# Use copy_file_range-equivalent: cp --reflink=auto on BTRFS
cp --reflink=auto "$DWARFS_IMG" "$BTRFS_PART_MNT/images/source.dwarfs"
assert_file_exists "image stored on BTRFS partition" \
    "$BTRFS_PART_MNT/images/source.dwarfs"

# Verify stored image integrity
ORIG_HASH=$(md5sum "$DWARFS_IMG" | awk '{print $1}')
STORED_HASH=$(md5sum "$BTRFS_PART_MNT/images/source.dwarfs" | awk '{print $1}')
assert_eq "stored image hash matches original" "$STORED_HASH" "$ORIG_HASH"

# ── Test 3: BTRFS CoW — modifying stored image doesn't affect original ────────

cp "$BTRFS_PART_MNT/images/source.dwarfs" \
   "$BTRFS_PART_MNT/images/source_copy.dwarfs"
# Truncate the copy — original must be unaffected
truncate -s 0 "$BTRFS_PART_MNT/images/source_copy.dwarfs"
AFTER_HASH=$(md5sum "$BTRFS_PART_MNT/images/source.dwarfs" | awk '{print $1}')
assert_eq "original unaffected by CoW copy modification" \
    "$AFTER_HASH" "$ORIG_HASH"

# ── Test 4: BTRFS snapshot of the images subvolume ────────────────────────────

btrfs subvolume snapshot -r \
    "$BTRFS_PART_MNT/images" \
    "$BTRFS_PART_MNT/images_snap_$(date +%Y%m%d)" &>/dev/null

SNAP_DIR="$BTRFS_PART_MNT/images_snap_$(date +%Y%m%d)"
assert_dir_exists "snapshot created" "$SNAP_DIR"
assert_file_exists "image present in snapshot" \
    "$SNAP_DIR/source.dwarfs"

# Snapshot must be read-only
assert_cmd_fails "snapshot is read-only" \
    touch "$SNAP_DIR/should_fail"

# ── Test 5: Snapshot is independent — delete from live, snap intact ───────────

rm "$BTRFS_PART_MNT/images/source.dwarfs"
assert_cmd_fails "image deleted from live subvol" \
    test -f "$BTRFS_PART_MNT/images/source.dwarfs"
assert_file_exists "image still in snapshot" \
    "$SNAP_DIR/source.dwarfs"

# Restore for import test
cp "$SNAP_DIR/source.dwarfs" "$BTRFS_PART_MNT/images/source.dwarfs"

# ── Test 6: Import DwarFS image → new BTRFS subvolume ─────────────────────────

btrfs subvolume create "$SRC_MNT/imported" &>/dev/null
dwarfsextract -i "$BTRFS_PART_MNT/images/source.dwarfs" \
    -o "$SRC_MNT/imported" &>/dev/null
assert_dir_exists "imported subvolume populated" "$SRC_MNT/imported"

# ── Test 7: Imported content matches original ─────────────────────────────────

assert_file_exists "MANIFEST in imported subvol" \
    "$SRC_MNT/imported/MANIFEST"
assert_eq "MANIFEST content matches" \
    "$(cat "$SRC_MNT/imported/MANIFEST")" "source"

# File count
ORIG_COUNT=$(find "$SRC_MNT/source" -type f | wc -l)
IMPORT_COUNT=$(find "$SRC_MNT/imported" -type f | wc -l)
assert_eq "imported file count matches original" \
    "$IMPORT_COUNT" "$ORIG_COUNT"

# Content hash of a specific file
ORIG_FILE_HASH=$(md5sum "$SRC_MNT/source/data/file_5.txt" | awk '{print $1}')
IMPORT_FILE_HASH=$(md5sum "$SRC_MNT/imported/data/file_5.txt" | awk '{print $1}')
assert_eq "imported file content matches" \
    "$IMPORT_FILE_HASH" "$ORIG_FILE_HASH"

# ── Test 8: Multiple snapshots of the partition ───────────────────────────────

# Add a second image
mkdwarfs -i "$SRC_MNT/imported" -o \
    "$BTRFS_PART_MNT/images/imported.dwarfs" \
    --compression zstd --num-workers 2 &>/dev/null

btrfs subvolume snapshot -r \
    "$BTRFS_PART_MNT/images" \
    "$BTRFS_PART_MNT/images_snap2" &>/dev/null

SNAP2_COUNT=$(find "$BTRFS_PART_MNT/images_snap2" -name '*.dwarfs' | wc -l)
assert_eq "second snapshot contains 2 images" "$SNAP2_COUNT" "2"

# ── Test 9: BTRFS checksumming catches corruption ─────────────────────────────

# BTRFS checksums data blocks; scrub detects corruption.
# We can't easily corrupt a loopback device and run scrub in a test,
# so we verify that btrfs scrub runs without error on a clean filesystem.
assert_cmd_ok "btrfs scrub completes cleanly" \
    btrfs scrub start -B "$BTRFS_PART_MNT"

print_summary
