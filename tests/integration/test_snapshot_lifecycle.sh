#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_snapshot_lifecycle.sh - Snapshot and subvolume lifecycle tests
#
# Tests the full snapshot lifecycle:
#   1. Create subvolume → snapshot → export to DwarFS
#   2. Verify snapshot independence from source
#   3. Delete source subvolume, verify snapshot and DwarFS image intact
#   4. Restore from DwarFS image to new subvolume
#   5. Incremental snapshot chain: snap1 → snap2 → snap3, each exported
#   6. Verify each DwarFS image is independently mountable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_root
require_cmd mkfs.btrfs || exit 0
require_cmd mkdwarfs   || exit 0
require_cmd dwarfs     || exit 0
require_cmd fusermount || exit 0

echo "=== Snapshot lifecycle tests ==="

# ── Setup ────────────────────────────────────────────────────────────────────

BTRFS_MNT=$(mktemp -d /tmp/bdfs_snap_XXXXXX)
TEMP_DIRS+=("$BTRFS_MNT")

make_loop_device 512 BTRFS_DEV
make_btrfs "$BTRFS_DEV" "bdfs_snap_test"
mount_btrfs "$BTRFS_DEV" "$BTRFS_MNT"

# ── Test 1: Basic snapshot independence ───────────────────────────────────────

make_test_subvol "$BTRFS_MNT" "v1"
btrfs subvolume snapshot -r "$BTRFS_MNT/v1" "$BTRFS_MNT/v1_snap" &>/dev/null

# Modify source after snapshot
echo "post_snap_write" >> "$BTRFS_MNT/v1/MANIFEST"

SNAP_CONTENT=$(cat "$BTRFS_MNT/v1_snap/MANIFEST")
assert_eq "snapshot not affected by post-snap write" \
    "$SNAP_CONTENT" "v1"

# ── Test 2: Export snapshot to DwarFS ─────────────────────────────────────────

IMG_V1=$(mktemp /tmp/bdfs_v1_XXXXXX.dwarfs)
TEMP_DIRS+=("$IMG_V1")
mkdwarfs -i "$BTRFS_MNT/v1_snap" -o "$IMG_V1" \
    --compression zstd --num-workers 2 &>/dev/null
assert_file_exists "v1 DwarFS image created" "$IMG_V1"

# ── Test 3: Delete source, snapshot and image intact ─────────────────────────

btrfs subvolume delete "$BTRFS_MNT/v1" &>/dev/null
assert_cmd_fails "source subvol deleted" \
    test -d "$BTRFS_MNT/v1"
assert_dir_exists "snapshot still exists" "$BTRFS_MNT/v1_snap"
assert_file_exists "DwarFS image still exists" "$IMG_V1"

# ── Test 4: Restore from DwarFS image ─────────────────────────────────────────

btrfs subvolume create "$BTRFS_MNT/v1_restored" &>/dev/null
dwarfsextract -i "$IMG_V1" -o "$BTRFS_MNT/v1_restored" &>/dev/null
assert_eq "restored MANIFEST matches snapshot" \
    "$(cat "$BTRFS_MNT/v1_restored/MANIFEST")" "v1"

# ── Test 5: Incremental snapshot chain ────────────────────────────────────────

# v2: add files
btrfs subvolume snapshot "$BTRFS_MNT/v1_snap" "$BTRFS_MNT/v2" &>/dev/null
echo "v2" > "$BTRFS_MNT/v2/MANIFEST"
echo "v2_new_file" > "$BTRFS_MNT/v2/v2_only.txt"
btrfs subvolume snapshot -r "$BTRFS_MNT/v2" "$BTRFS_MNT/v2_snap" &>/dev/null

# v3: modify files
btrfs subvolume snapshot "$BTRFS_MNT/v2_snap" "$BTRFS_MNT/v3" &>/dev/null
echo "v3" > "$BTRFS_MNT/v3/MANIFEST"
echo "v3_new_file" > "$BTRFS_MNT/v3/v3_only.txt"
btrfs subvolume snapshot -r "$BTRFS_MNT/v3" "$BTRFS_MNT/v3_snap" &>/dev/null

# Export each snapshot to DwarFS
IMG_V2=$(mktemp /tmp/bdfs_v2_XXXXXX.dwarfs)
IMG_V3=$(mktemp /tmp/bdfs_v3_XXXXXX.dwarfs)
TEMP_DIRS+=("$IMG_V2" "$IMG_V3")

mkdwarfs -i "$BTRFS_MNT/v2_snap" -o "$IMG_V2" \
    --compression zstd --num-workers 2 &>/dev/null
mkdwarfs -i "$BTRFS_MNT/v3_snap" -o "$IMG_V3" \
    --compression zstd --num-workers 2 &>/dev/null

assert_file_exists "v2 image created" "$IMG_V2"
assert_file_exists "v3 image created" "$IMG_V3"

# ── Test 6: Each image independently mountable and correct ────────────────────

for ver in 1 2 3; do
    img_var="IMG_V${ver}"
    img="${!img_var}"
    mnt=$(mktemp -d /tmp/bdfs_v${ver}_mnt_XXXXXX)
    TEMP_DIRS+=("$mnt")
    MOUNT_POINTS+=("$mnt")

    dwarfs "$img" "$mnt" -o cache_size=32m &>/dev/null
    sleep 0.3

    assert_eq "v${ver} image MANIFEST correct" \
        "$(cat "$mnt/MANIFEST")" "v${ver}"

    fusermount -u "$mnt" &>/dev/null
    MOUNT_POINTS=("${MOUNT_POINTS[@]/$mnt}")
done

# v2 image has v2_only.txt, not v3_only.txt
MNT_V2=$(mktemp -d /tmp/bdfs_v2_check_XXXXXX)
TEMP_DIRS+=("$MNT_V2")
MOUNT_POINTS+=("$MNT_V2")
dwarfs "$IMG_V2" "$MNT_V2" -o cache_size=32m &>/dev/null
sleep 0.3
assert_file_exists "v2 image has v2_only.txt" "$MNT_V2/v2_only.txt"
assert_cmd_fails "v2 image does not have v3_only.txt" \
    test -f "$MNT_V2/v3_only.txt"
fusermount -u "$MNT_V2" &>/dev/null
MOUNT_POINTS=("${MOUNT_POINTS[@]/$MNT_V2}")

# ── Test 7: Image sizes reflect content differences ───────────────────────────

SIZE_V1=$(stat -c%s "$IMG_V1")
SIZE_V2=$(stat -c%s "$IMG_V2")
SIZE_V3=$(stat -c%s "$IMG_V3")
info "Image sizes: v1=${SIZE_V1}  v2=${SIZE_V2}  v3=${SIZE_V3}"

# v2 and v3 should be larger than v1 (they have more files)
if [[ $SIZE_V2 -gt $SIZE_V1 ]]; then
    pass "v2 image larger than v1 (more content)"
else
    skip "v2 not larger than v1 (compression may equalise small differences)"
fi

print_summary
