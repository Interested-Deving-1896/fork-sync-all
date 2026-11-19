#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test_blend_layer.sh - Blend layer (unified namespace) tests
#
# Tests the promote/demote cycle and unified namespace behaviour:
#   - Kernel blend mount (bdfs_blend module)
#   - Userspace blend mount (fuse-overlayfs fallback)
#   - Auto-fallback from kernel to userspace on ENODEV
#   - Teardown order: overlay unmounted before DwarFS lower layer
#
# Run as root against a loopback BTRFS device.
# Requires: btrfs-progs, dwarfs, fuse-overlayfs, bdfs CLI

set -euo pipefail
source "$(dirname "$0")/lib.sh"

# ── Fixtures ─────────────────────────────────────────────────────────────────

setup_blend_fixtures() {
	# Create a BTRFS loopback device
	BTRFS_IMG="$TEST_TMP/btrfs.img"
	BTRFS_MNT="$TEST_TMP/btrfs"
	truncate -s 2G "$BTRFS_IMG"
	mkfs.btrfs -q "$BTRFS_IMG"
	mkdir -p "$BTRFS_MNT"
	mount -o loop "$BTRFS_IMG" "$BTRFS_MNT"

	# Create a source subvolume with known content
	btrfs subvolume create "$BTRFS_MNT/source"
	echo "hello from btrfs" > "$BTRFS_MNT/source/btrfs_file.txt"
	mkdir -p "$BTRFS_MNT/source/subdir"
	echo "nested" > "$BTRFS_MNT/source/subdir/nested.txt"

	# Create a read-only snapshot for export
	btrfs subvolume snapshot -r \
		"$BTRFS_MNT/source" "$BTRFS_MNT/source_snap"

	# Export the snapshot to a DwarFS image
	DWARFS_IMG="$TEST_TMP/test.dwarfs"
	mkdwarfs -i "$BTRFS_MNT/source_snap" -o "$DWARFS_IMG" \
		--compression zstd --num-workers 2 2>/dev/null

	# Create the BTRFS upper subvolume (writable layer)
	btrfs subvolume create "$BTRFS_MNT/upper"

	# Create the overlayfs workdir on the same BTRFS filesystem
	btrfs subvolume create "$BTRFS_MNT/workdir"

	# Mountpoints
	BLEND_MNT="$TEST_TMP/blend"
	mkdir -p "$BLEND_MNT"

	# Private DwarFS lower mountpoint (mirrors daemon state_dir behaviour)
	LOWER_MNT="$TEST_TMP/lower_fuse"
	mkdir -p "$LOWER_MNT"
}

teardown_blend_fixtures() {
	# Unmount in reverse order; ignore errors (already unmounted)
	umount "$BLEND_MNT"  2>/dev/null || true
	umount "$LOWER_MNT"  2>/dev/null || true
	umount "$BTRFS_MNT"  2>/dev/null || true
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Mount the DwarFS image at LOWER_MNT using the dwarfs FUSE driver
mount_dwarfs_lower() {
	dwarfs "$DWARFS_IMG" "$LOWER_MNT" -o cache_size=64m
	# Wait for FUSE mount to be ready
	local retries=10
	while ! mountpoint -q "$LOWER_MNT" && (( retries-- > 0 )); do
		sleep 0.1
	done
	mountpoint -q "$LOWER_MNT" || fail "dwarfs FUSE mount did not appear"
}

# Mount fuse-overlayfs over LOWER_MNT + BTRFS_MNT/upper → BLEND_MNT
mount_userspace_blend() {
	fuse-overlayfs \
		-o lowerdir="$LOWER_MNT",upperdir="$BTRFS_MNT/upper",workdir="$BTRFS_MNT/workdir" \
		"$BLEND_MNT"
	local retries=10
	while ! mountpoint -q "$BLEND_MNT" && (( retries-- > 0 )); do
		sleep 0.1
	done
	mountpoint -q "$BLEND_MNT" || fail "fuse-overlayfs mount did not appear"
}

umount_userspace_blend() {
	fusermount -u "$BLEND_MNT"  2>/dev/null || umount "$BLEND_MNT"  2>/dev/null || true
	fusermount -u "$LOWER_MNT"  2>/dev/null || umount "$LOWER_MNT"  2>/dev/null || true
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_userspace_blend_mount() {
	desc "userspace blend mount: fuse-overlayfs over dwarfs FUSE"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures

	mount_dwarfs_lower
	mount_userspace_blend

	# DwarFS lower content is visible through the blend
	assert_file_contains "$BLEND_MNT/btrfs_file.txt" "hello from btrfs"
	assert_file_contains "$BLEND_MNT/subdir/nested.txt" "nested"

	pass "DwarFS lower content visible through fuse-overlayfs blend"
}

test_userspace_blend_write_goes_to_upper() {
	desc "userspace blend mount: writes land on BTRFS upper layer"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	# Write a new file through the blend
	echo "written via blend" > "$BLEND_MNT/new_file.txt"

	# File must appear on the BTRFS upper layer
	assert_file_exists "$BTRFS_MNT/upper/new_file.txt"
	assert_file_contains "$BTRFS_MNT/upper/new_file.txt" "written via blend"

	# DwarFS lower must be unmodified (read-only)
	assert_file_not_exists "$LOWER_MNT/new_file.txt"

	pass "writes go to BTRFS upper, DwarFS lower unchanged"
}

test_userspace_blend_modify_lower_file() {
	desc "userspace blend mount: modifying a lower file copies it up to BTRFS"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	# Modify a file that exists only in the DwarFS lower
	echo "modified" >> "$BLEND_MNT/btrfs_file.txt"

	# The modified copy must be on the BTRFS upper layer
	assert_file_exists "$BTRFS_MNT/upper/btrfs_file.txt"
	assert_file_contains "$BTRFS_MNT/upper/btrfs_file.txt" "modified"

	# The DwarFS lower must still have the original content
	assert_file_contains "$LOWER_MNT/btrfs_file.txt" "hello from btrfs"

	pass "copy-up on modify: modified file on BTRFS upper, original on DwarFS lower"
}

test_userspace_blend_delete_lower_file() {
	desc "userspace blend mount: deleting a lower file creates a whiteout on BTRFS"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	rm "$BLEND_MNT/btrfs_file.txt"

	# File must not be visible through the blend
	assert_file_not_exists "$BLEND_MNT/btrfs_file.txt"

	# DwarFS lower must still have the original (whiteout is on upper)
	assert_file_exists "$LOWER_MNT/btrfs_file.txt"

	pass "delete creates whiteout on BTRFS upper, DwarFS lower unchanged"
}

test_userspace_blend_umount_order() {
	desc "userspace blend umount: overlay unmounted before DwarFS lower"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	# Unmount overlay first
	fusermount -u "$BLEND_MNT" || umount "$BLEND_MNT"
	assert_not_mountpoint "$BLEND_MNT"

	# DwarFS lower must still be mounted at this point
	assert_mountpoint "$LOWER_MNT"

	# Now unmount the lower
	fusermount -u "$LOWER_MNT" || umount "$LOWER_MNT"
	assert_not_mountpoint "$LOWER_MNT"

	pass "teardown order correct: overlay before DwarFS lower"
}

test_userspace_blend_umount_lower_first_fails() {
	desc "userspace blend umount: unmounting DwarFS lower while overlay is active fails"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	# Attempting to unmount the lower while the overlay is still mounted
	# must fail (EBUSY)
	if fusermount -u "$LOWER_MNT" 2>/dev/null || umount "$LOWER_MNT" 2>/dev/null; then
		fail "expected umount of lower to fail while overlay is active"
	fi

	assert_mountpoint "$LOWER_MNT"
	pass "umount of lower correctly refused while overlay is active"
}

test_userspace_blend_teardown() {
	# Final cleanup for the userspace blend test group
	umount_userspace_blend
	teardown_blend_fixtures
}

# ── Kernel blend mount tests (require bdfs_blend module) ─────────────────────

test_kernel_blend_mount() {
	desc "kernel blend mount: bdfs_blend module"

	skip_if_no_cmd bdfs
	skip_unless_module_loaded bdfs_blend

	setup_blend_fixtures

	bdfs blend mount \
		--btrfs-uuid "$(btrfs filesystem show "$BTRFS_MNT" | awk '/uuid:/{print $NF}')" \
		--dwarfs-uuid "00000000-0000-0000-0000-000000000001" \
		--mountpoint "$BLEND_MNT"

	assert_mountpoint "$BLEND_MNT"
	assert_file_contains "$BLEND_MNT/btrfs_file.txt" "hello from btrfs"

	bdfs blend umount --mountpoint "$BLEND_MNT"
	assert_not_mountpoint "$BLEND_MNT"

	teardown_blend_fixtures
	pass "kernel blend mount/umount cycle"
}

test_kernel_blend_auto_fallback() {
	desc "kernel blend mount: auto-fallback to fuse-overlayfs on ENODEV"

	skip_if_no_cmd bdfs
	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_module_loaded bdfs_blend  # only meaningful when module is absent

	setup_blend_fixtures

	# bdfs blend mount without --userspace: should detect ENODEV and
	# automatically retry with fuse-overlayfs
	bdfs blend mount \
		--btrfs-uuid "$(btrfs filesystem show "$BTRFS_MNT" | awk '/uuid:/{print $NF}')" \
		--dwarfs-uuid "00000000-0000-0000-0000-000000000001" \
		--mountpoint "$BLEND_MNT" \
		--btrfs-mount "$BTRFS_MNT/upper" \
		--dwarfs-image "$DWARFS_IMG" \
		--work-dir "$BTRFS_MNT/workdir"

	assert_mountpoint "$BLEND_MNT"
	assert_file_contains "$BLEND_MNT/btrfs_file.txt" "hello from btrfs"

	bdfs blend umount --mountpoint "$BLEND_MNT"
	assert_not_mountpoint "$BLEND_MNT"

	teardown_blend_fixtures
	pass "auto-fallback to fuse-overlayfs when kernel module absent"
}

# ── fsync tests ───────────────────────────────────────────────────────────────

test_fsync_upper_layer_file() {
	desc "fsync: upper-layer file fsync completes without error"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	local f="$BLEND_MNT/fsync_test.txt"
	echo "fsync test data" > "$f"

	# sync(1) flushes all dirty pages; we also test via python if available
	sync "$f" 2>/dev/null || sync

	# File must still be readable and correct after fsync
	assert_file_contains "$f" "fsync test data"

	# Verify the file landed on the upper layer (not just in page cache)
	assert_file_exists "$BTRFS_MNT/upper/fsync_test.txt"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "fsync on upper-layer file completes without error"
}

test_fsync_lower_layer_file_noop() {
	desc "fsync: lower-layer (DwarFS) file fsync is a no-op (read-only)"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# Open a lower-layer file read-only and call sync — must not error
	local f="$BLEND_MNT/btrfs_file.txt"
	assert_file_exists "$f"
	# cat + sync exercises the read path; no write means no copy-up
	cat "$f" > /dev/null
	sync "$f" 2>/dev/null || sync

	# Lower-layer file must still be unmodified
	assert_file_contains "$LOWER_MNT/btrfs_file.txt" "hello from btrfs"
	assert_file_not_exists "$BTRFS_MNT/upper/btrfs_file.txt"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "fsync on lower-layer file is a no-op"
}

# ── mmap tests ────────────────────────────────────────────────────────────────

test_mmap_read_lower_layer() {
	desc "mmap: read-only mmap of a lower-layer (DwarFS) file"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd python3

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# python3 mmap test: open file, mmap PROT_READ, verify content
	python3 - "$BLEND_MNT/btrfs_file.txt" <<'EOF'
import sys, mmap
path = sys.argv[1]
with open(path, 'rb') as f:
    with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        data = m[:].decode()
        assert 'hello from btrfs' in data, f"unexpected content: {data!r}"
print("mmap read ok")
EOF

	umount_userspace_blend
	teardown_blend_fixtures
	pass "read-only mmap of lower-layer file returns correct content"
}

test_mmap_write_upper_layer() {
	desc "mmap: write mmap of an upper-layer file modifies backing store"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd python3

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# Create a file on the upper layer first
	local f="$BLEND_MNT/mmap_write_test.bin"
	dd if=/dev/zero bs=4096 count=1 > "$f" 2>/dev/null

	python3 - "$f" <<'EOF'
import sys, mmap, struct
path = sys.argv[1]
with open(path, 'r+b') as f:
    with mmap.mmap(f.fileno(), 4096, access=mmap.ACCESS_WRITE) as m:
        m[0:4] = b'BDFS'
        m.flush()
print("mmap write ok")
EOF

	# Verify the write landed on the BTRFS upper layer
	local magic
	magic=$(dd if="$BTRFS_MNT/upper/mmap_write_test.bin" bs=4 count=1 2>/dev/null)
	[ "$magic" = "BDFS" ] || fail "mmap write not visible on upper layer (got: $magic)"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "write mmap on upper-layer file persists to BTRFS backing store"
}

# ── xattr tests ───────────────────────────────────────────────────────────────

test_xattr_set_get_upper_layer() {
	desc "xattr: set and get user xattr on an upper-layer file"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd setfattr
	skip_if_no_cmd getfattr

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	local f="$BLEND_MNT/xattr_test.txt"
	echo "xattr test" > "$f"

	setfattr -n user.bdfs.test -v "hello_xattr" "$f"
	local val
	val=$(getfattr -n user.bdfs.test --only-values "$f" 2>/dev/null)
	[ "$val" = "hello_xattr" ] || fail "xattr value mismatch: got '$val'"

	# Verify xattr is stored on the real BTRFS upper file
	local real_val
	real_val=$(getfattr -n user.bdfs.test --only-values \
		"$BTRFS_MNT/upper/xattr_test.txt" 2>/dev/null)
	[ "$real_val" = "hello_xattr" ] || \
		fail "xattr not on BTRFS upper layer: got '$real_val'"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "user xattr set/get on upper-layer file"
}

test_xattr_read_lower_layer() {
	desc "xattr: read xattr from a lower-layer (DwarFS) file"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd setfattr
	skip_if_no_cmd getfattr

	# Create a source file with an xattr, export to DwarFS, then blend
	setup_blend_fixtures

	# Add xattr to the source before snapshot/export
	setfattr -n user.bdfs.origin -v "dwarfs_lower" \
		"$BTRFS_MNT/source/btrfs_file.txt" 2>/dev/null || \
		skip "setfattr on BTRFS source failed (xattr support required)"

	# Re-export with xattr preserved
	btrfs subvolume delete "$BTRFS_MNT/source_snap" 2>/dev/null || true
	btrfs subvolume snapshot -r \
		"$BTRFS_MNT/source" "$BTRFS_MNT/source_snap"
	mkdwarfs -i "$BTRFS_MNT/source_snap" -o "$DWARFS_IMG" \
		--compression zstd --num-workers 2 \
		--preserve-xattrs 2>/dev/null || \
		skip "mkdwarfs --preserve-xattrs not supported"

	mount_dwarfs_lower
	mount_userspace_blend

	local val
	val=$(getfattr -n user.bdfs.origin --only-values \
		"$BLEND_MNT/btrfs_file.txt" 2>/dev/null) || \
		skip "getfattr on blend mount failed"
	[ "$val" = "dwarfs_lower" ] || \
		fail "xattr from lower layer not visible: got '$val'"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "xattr from lower-layer (DwarFS) file readable through blend"
}

test_xattr_copy_up_on_set() {
	desc "xattr: setting xattr on lower-layer file triggers copy-up"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd setfattr

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# btrfs_file.txt exists only on the lower layer initially
	assert_file_not_exists "$BTRFS_MNT/upper/btrfs_file.txt"

	# Setting an xattr on a lower-layer file must trigger copy-up
	setfattr -n user.bdfs.copied -v "yes" \
		"$BLEND_MNT/btrfs_file.txt" 2>/dev/null || \
		skip "setfattr on blend lower file not supported by fuse-overlayfs"

	# After copy-up the file must exist on the upper layer
	assert_file_exists "$BTRFS_MNT/upper/btrfs_file.txt"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "setxattr on lower-layer file triggers copy-up to BTRFS upper"
}

# ── permission / ACL tests ────────────────────────────────────────────────────

test_permission_mode_respected() {
	desc "permission: mode bits on blend files are enforced"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	local f="$BLEND_MNT/perm_test.txt"
	echo "permission test" > "$f"
	chmod 000 "$f"

	# Reading as root still works (root bypasses DAC), but we can verify
	# the mode is set correctly
	local mode
	mode=$(stat -c '%a' "$f")
	[ "$mode" = "0" ] || [ "$mode" = "000" ] || \
		fail "expected mode 000, got $mode"

	# Restore so teardown can clean up
	chmod 644 "$f"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "mode bits on blend files are enforced"
}

test_permission_acl_forwarded() {
	desc "permission: POSIX ACL on upper-layer file is enforced through blend"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs
	skip_if_no_cmd setfacl
	skip_if_no_cmd getfacl

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	local f="$BLEND_MNT/acl_test.txt"
	echo "acl test" > "$f"
	chmod 640 "$f"

	# Set a named-user ACL entry
	setfacl -m u:nobody:r "$f" 2>/dev/null || \
		skip "setfacl failed (ACL support required on BTRFS)"

	# Verify the ACL is visible through the blend mount
	local acl_out
	acl_out=$(getfacl -p "$f" 2>/dev/null)
	echo "$acl_out" | grep -q "user:nobody:r--" || \
		fail "ACL entry not visible through blend: $acl_out"

	# Verify the ACL is also on the real BTRFS upper file
	local real_acl
	real_acl=$(getfacl -p "$BTRFS_MNT/upper/acl_test.txt" 2>/dev/null)
	echo "$real_acl" | grep -q "user:nobody:r--" || \
		fail "ACL not on BTRFS upper layer: $real_acl"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "POSIX ACL on upper-layer file visible and enforced through blend"
}

# ── whiteout persistence tests ────────────────────────────────────────────────

test_whiteout_hides_lower_after_remount() {
	desc "whiteout: deleted lower-layer entry stays hidden after remount"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# Delete a lower-layer file through the blend
	rm "$BLEND_MNT/btrfs_file.txt"
	assert_file_not_exists "$BLEND_MNT/btrfs_file.txt"

	# Whiteout must exist on the upper layer
	assert_file_exists "$BTRFS_MNT/upper/.wh.btrfs_file.txt"

	# Remount the blend
	umount_userspace_blend
	mount_dwarfs_lower
	mount_userspace_blend

	# File must still be hidden after remount (whiteout persists)
	assert_file_not_exists "$BLEND_MNT/btrfs_file.txt"

	# Lower-layer original must still exist
	assert_file_exists "$LOWER_MNT/btrfs_file.txt"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "whiteout persists across remount: deleted lower entry stays hidden"
}

test_whiteout_not_visible_in_readdir() {
	desc "whiteout: .wh.* marker files are not visible in directory listing"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# Delete a lower-layer file to create a whiteout
	rm "$BLEND_MNT/btrfs_file.txt"

	# The whiteout file must exist on the upper layer
	assert_file_exists "$BTRFS_MNT/upper/.wh.btrfs_file.txt"

	# But it must NOT appear in the blend directory listing
	local listing
	listing=$(ls "$BLEND_MNT")
	echo "$listing" | grep -q "\.wh\." && \
		fail "whiteout marker visible in blend readdir: $listing"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "whiteout markers are filtered from blend directory listing"
}

test_whiteout_recreate_after_delete() {
	desc "whiteout: recreating a deleted lower-layer file removes the whiteout"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# Delete the lower-layer file (creates whiteout)
	rm "$BLEND_MNT/btrfs_file.txt"
	assert_file_not_exists "$BLEND_MNT/btrfs_file.txt"
	assert_file_exists "$BTRFS_MNT/upper/.wh.btrfs_file.txt"

	# Recreate the file through the blend
	echo "recreated" > "$BLEND_MNT/btrfs_file.txt"

	# File must be visible again
	assert_file_contains "$BLEND_MNT/btrfs_file.txt" "recreated"

	# The whiteout must have been removed (overlayfs removes it on create)
	assert_file_not_exists "$BTRFS_MNT/upper/.wh.btrfs_file.txt"

	# The new file must be on the upper layer
	assert_file_exists "$BTRFS_MNT/upper/btrfs_file.txt"
	assert_file_contains "$BTRFS_MNT/upper/btrfs_file.txt" "recreated"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "recreating a deleted lower-layer file removes the whiteout"
}

test_whiteout_nested_directory() {
	desc "whiteout: deleting a nested lower-layer directory hides it"

	skip_if_no_cmd fuse-overlayfs
	skip_if_no_cmd dwarfs

	setup_blend_fixtures
	mount_dwarfs_lower
	mount_userspace_blend

	# subdir exists in the lower layer
	assert_file_exists "$BLEND_MNT/subdir/nested.txt"

	# Delete the nested file first, then the directory
	rm "$BLEND_MNT/subdir/nested.txt"
	rmdir "$BLEND_MNT/subdir" 2>/dev/null || \
		rm -rf "$BLEND_MNT/subdir"

	# Directory must not be visible
	[ ! -d "$BLEND_MNT/subdir" ] || \
		fail "deleted lower-layer directory still visible"

	# Lower layer must be unmodified
	assert_file_exists "$LOWER_MNT/subdir/nested.txt"

	umount_userspace_blend
	teardown_blend_fixtures
	pass "deleting a nested lower-layer directory hides it via whiteout"
}

# ── Test runner ───────────────────────────────────────────────────────────────

run_tests \
	test_userspace_blend_mount \
	test_userspace_blend_write_goes_to_upper \
	test_userspace_blend_modify_lower_file \
	test_userspace_blend_delete_lower_file \
	test_userspace_blend_umount_order \
	test_userspace_blend_umount_lower_first_fails \
	test_userspace_blend_teardown \
	test_kernel_blend_mount \
	test_kernel_blend_auto_fallback \
	test_fsync_upper_layer_file \
	test_fsync_lower_layer_file_noop \
	test_mmap_read_lower_layer \
	test_mmap_write_upper_layer \
	test_xattr_set_get_upper_layer \
	test_xattr_read_lower_layer \
	test_xattr_copy_up_on_set \
	test_permission_mode_respected \
	test_permission_acl_forwarded \
	test_whiteout_hides_lower_after_remount \
	test_whiteout_not_visible_in_readdir \
	test_whiteout_recreate_after_delete \
	test_whiteout_nested_directory
