#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# bdfs-genfstab.sh - Generate /etc/fstab entries for a BTRFS filesystem
#
# Introspects the live subvolume layout of a mounted BTRFS filesystem and
# generates fstab entries for every subvolume found.  Does not assume any
# naming convention (@, @home, etc.) — it works with whatever subvolumes
# actually exist.
#
# Usage:
#   bdfs-genfstab.sh [OPTIONS]
#
# Options:
#   -m, --mountpoint <path>   BTRFS root mountpoint to introspect
#                             (default: /)
#   -d, --device <path>       Block device or UUID=... to use in fstab
#                             (default: auto-detected from mountpoint)
#   -o, --output <path>       Write output to file instead of stdout
#   -a, --append              Append to output file (skip existing entries)
#   -n, --dry-run             Print what would be written, make no changes
#       --no-compress         Omit compress=zstd from mount options
#       --no-discard          Omit discard=async even on SSDs
#       --no-space-cache      Omit space_cache=v2
#   -h, --help                Show this help
#
# Requirements: btrfs-progs, findmnt, lsblk, awk, grep (all standard)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

MOUNTPOINT="/"
DEVICE=""
OUTPUT=""
APPEND=false
DRY_RUN=false
OPT_COMPRESS=true
OPT_DISCARD=auto   # auto = detect SSD
OPT_SPACE_CACHE=true

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
	sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
	exit 0
}

die() { echo "bdfs-genfstab: error: $*" >&2; exit 1; }
info() { echo "bdfs-genfstab: $*" >&2; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	-m|--mountpoint) MOUNTPOINT="$2"; shift 2 ;;
	-d|--device)     DEVICE="$2";     shift 2 ;;
	-o|--output)     OUTPUT="$2";     shift 2 ;;
	-a|--append)     APPEND=true;     shift   ;;
	-n|--dry-run)    DRY_RUN=true;    shift   ;;
	--no-compress)   OPT_COMPRESS=false; shift ;;
	--no-discard)    OPT_DISCARD=no;  shift   ;;
	--no-space-cache) OPT_SPACE_CACHE=false; shift ;;
	-h|--help)       usage ;;
	*) die "unknown option: $1" ;;
	esac
done

# ── Prerequisite checks ───────────────────────────────────────────────────────

for cmd in btrfs findmnt lsblk awk; do
	command -v "$cmd" >/dev/null 2>&1 \
		|| die "required tool not found: $cmd"
done

[[ -d "$MOUNTPOINT" ]] || die "mountpoint does not exist: $MOUNTPOINT"

# Verify the mountpoint is actually a BTRFS filesystem
FS_TYPE=$(findmnt -n -o FSTYPE "$MOUNTPOINT" 2>/dev/null || true)
[[ "$FS_TYPE" == "btrfs" ]] \
	|| die "$MOUNTPOINT is not a BTRFS filesystem (found: ${FS_TYPE:-unknown})"

# ── Device detection ──────────────────────────────────────────────────────────

if [[ -z "$DEVICE" ]]; then
	# Prefer UUID= form for robustness across reboots
	FS_UUID=$(findmnt -n -o UUID "$MOUNTPOINT" 2>/dev/null || true)
	if [[ -n "$FS_UUID" ]]; then
		DEVICE="UUID=$FS_UUID"
	else
		DEVICE=$(findmnt -n -o SOURCE "$MOUNTPOINT")
	fi
fi

info "device: $DEVICE"
info "mountpoint: $MOUNTPOINT"

# ── SSD detection for discard=async ──────────────────────────────────────────

detect_ssd() {
	local source
	source=$(findmnt -n -o SOURCE "$MOUNTPOINT" 2>/dev/null || true)
	[[ -z "$source" ]] && return 1

	# Strip partition suffix to get the base device (e.g. /dev/sda1 → sda)
	local dev
	dev=$(basename "$source" | sed 's/[0-9]*$//')

	# lsblk ROTA: 0 = SSD/NVMe, 1 = rotational
	local rota
	rota=$(lsblk -d -n -o ROTA "/dev/$dev" 2>/dev/null || echo "1")
	[[ "$rota" == "0" ]]
}

if [[ "$OPT_DISCARD" == "auto" ]]; then
	if detect_ssd; then
		OPT_DISCARD=yes
		info "SSD detected — adding discard=async"
	else
		OPT_DISCARD=no
		info "rotational disk detected — omitting discard=async"
	fi
fi

# ── Compression detection ─────────────────────────────────────────────────────

# Check whether the kernel supports zstd compression on this filesystem.
# We probe via btrfs filesystem show rather than assuming kernel version.
detect_zstd_support() {
	# zstd has been in the kernel since 4.14; check /proc/filesystems as
	# a proxy for whether the running kernel has btrfs zstd support.
	grep -q btrfs /proc/filesystems 2>/dev/null || return 1
	# btrfs-progs >= 4.14 supports zstd; check mkfs.btrfs --help output
	btrfs --help 2>&1 | grep -q zstd || return 1
	return 0
}

if $OPT_COMPRESS && ! detect_zstd_support; then
	info "zstd not available — omitting compress=zstd"
	OPT_COMPRESS=false
fi

# ── Build common mount options ────────────────────────────────────────────────

build_opts() {
	local subvol="$1"
	local opts="subvol=$subvol,noatime"

	$OPT_COMPRESS    && opts="$opts,compress=zstd:3"
	[[ "$OPT_DISCARD" == "yes" ]] && opts="$opts,discard=async"
	$OPT_SPACE_CACHE && opts="$opts,space_cache=v2"

	echo "$opts"
}

# ── Enumerate subvolumes ──────────────────────────────────────────────────────

# btrfs subvolume list outputs lines like:
#   ID 256 gen 7 top level 5 path @
#   ID 257 gen 8 top level 5 path @home
# We extract the path column (last field).

mapfile -t SUBVOLS < <(
	btrfs subvolume list -o "$MOUNTPOINT" 2>/dev/null \
		| awk '{print $NF}' \
		| sort
)

if [[ ${#SUBVOLS[@]} -eq 0 ]]; then
	info "no subvolumes found under $MOUNTPOINT"
	exit 0
fi

info "found ${#SUBVOLS[@]} subvolume(s)"

# ── Read existing fstab entries (for deduplication) ───────────────────────────

EXISTING_FSTAB=""
if $APPEND && [[ -n "$OUTPUT" && -f "$OUTPUT" ]]; then
	EXISTING_FSTAB=$(cat "$OUTPUT")
elif [[ -f /etc/fstab ]]; then
	EXISTING_FSTAB=$(cat /etc/fstab)
fi

entry_exists() {
	local subvol="$1"
	echo "$EXISTING_FSTAB" | grep -qF "subvol=$subvol"
}

# ── Generate entries ──────────────────────────────────────────────────────────

generate_entries() {
	local header_printed=false

	for subvol in "${SUBVOLS[@]}"; do
		if entry_exists "$subvol"; then
			info "skipping $subvol (already in fstab)"
			continue
		fi

		if ! $header_printed; then
			echo ""
			echo "# BTRFS subvolumes — generated by bdfs-genfstab"
			echo "# Device: $DEVICE"
			echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
			header_printed=true
		fi

		# Derive a sensible mountpoint from the subvolume path.
		# Strip a leading @ if present (common convention but not assumed).
		local mnt_suffix
		mnt_suffix=$(echo "$subvol" | sed 's|^@||; s|^/||')

		local mnt_point
		if [[ -z "$mnt_suffix" ]]; then
			mnt_point="/"
		else
			mnt_point="/$mnt_suffix"
		fi

		local opts
		opts=$(build_opts "$subvol")

		# fstab columns: device  mountpoint  fstype  options  dump  pass
		printf "%-40s %-20s %-6s %-60s %s %s\n" \
			"$DEVICE" \
			"$mnt_point" \
			"btrfs" \
			"$opts" \
			"0" \
			"0"
	done
}

# ── Output ────────────────────────────────────────────────────────────────────

ENTRIES=$(generate_entries)

if [[ -z "$ENTRIES" ]]; then
	info "no new entries to add"
	exit 0
fi

if $DRY_RUN; then
	echo "# --- dry run: would write the following ---"
	echo "$ENTRIES"
	exit 0
fi

if [[ -n "$OUTPUT" ]]; then
	if $APPEND; then
		echo "$ENTRIES" >> "$OUTPUT"
		info "appended entries to $OUTPUT"
	else
		echo "$ENTRIES" > "$OUTPUT"
		info "wrote entries to $OUTPUT"
	fi
else
	echo "$ENTRIES"
fi
