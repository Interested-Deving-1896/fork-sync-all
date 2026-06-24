#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# bdfs-balance.sh - Balance all BTRFS filesystems registered with bdfs
#
# Reads mountpoints from /etc/bdfs/scrub.conf (shared with scrub).
# Runs a metadata + data balance with usage filter to avoid unnecessary
# work on filesystems that are not fragmented.
#
# Balance filters used:
#   -dusage=50   Rebalance data chunks with < 50% usage
#   -musage=50   Rebalance metadata chunks with < 50% usage
#
# These are conservative defaults that avoid rewriting well-packed chunks.
# Override via BDFS_BALANCE_DUSAGE and BDFS_BALANCE_MUSAGE environment
# variables or /etc/bdfs/balance.conf.

set -euo pipefail

SCRUB_CONF="${BDFS_SCRUB_CONF:-/etc/bdfs/scrub.conf}"
BALANCE_CONF="${BDFS_BALANCE_CONF:-/etc/bdfs/balance.conf}"
DUSAGE="${BDFS_BALANCE_DUSAGE:-50}"
MUSAGE="${BDFS_BALANCE_MUSAGE:-50}"
LOG_TAG="bdfs-balance"
ERRORS=0

log() { echo "$*" | systemd-cat -t "$LOG_TAG" -p info; }
err() { echo "$*" | systemd-cat -t "$LOG_TAG" -p err; ERRORS=$((ERRORS+1)); }

# Override usage thresholds from balance.conf if present
if [[ -f "$BALANCE_CONF" ]]; then
	while IFS='=' read -r key val; do
		key="${key// /}"; val="${val// /}"
		[[ "$key" =~ ^# ]] && continue
		case "$key" in
		dusage) DUSAGE="$val" ;;
		musage) MUSAGE="$val" ;;
		esac
	done < "$BALANCE_CONF"
fi

# Collect mountpoints (same source as scrub)
declare -a MOUNTS=()

if [[ -f "$SCRUB_CONF" ]]; then
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// }" ]] && continue
		MOUNTS+=("$line")
	done < "$SCRUB_CONF"
fi

if [[ ${#MOUNTS[@]} -eq 0 ]]; then
	while IFS= read -r mnt; do
		[[ -n "$mnt" ]] && MOUNTS+=("$mnt")
	done < <(findmnt --real -t btrfs -lno TARGET 2>/dev/null || true)
fi

if [[ ${#MOUNTS[@]} -eq 0 ]]; then
	log "No BTRFS filesystems found to balance."
	exit 0
fi

log "Starting balance of ${#MOUNTS[@]} filesystem(s) " \
    "(dusage=${DUSAGE}%, musage=${MUSAGE}%)."

for mnt in "${MOUNTS[@]}"; do
	if ! mountpoint -q "$mnt" 2>/dev/null; then
		err "Skipping $mnt: not a mountpoint"
		continue
	fi

	# Check if a balance is already running
	if btrfs balance status "$mnt" 2>/dev/null | grep -q "running"; then
		log "Balance already running on $mnt — skipping."
		continue
	fi

	log "Balancing $mnt..."
	if btrfs balance start \
		-dusage="$DUSAGE" \
		-musage="$MUSAGE" \
		"$mnt" 2>&1 | systemd-cat -t "$LOG_TAG"; then
		log "Balance of $mnt completed."
	else
		# Exit code 1 from btrfs balance means "nothing to balance" — not an error
		exit_code=$?
		if [[ $exit_code -eq 1 ]]; then
			log "Balance of $mnt: nothing to rebalance."
		else
			err "Balance of $mnt failed (exit $exit_code)."
		fi
	fi
done

if [[ $ERRORS -gt 0 ]]; then
	log "Balance finished with $ERRORS error(s)."
	exit 1
fi
log "All balances completed successfully."
