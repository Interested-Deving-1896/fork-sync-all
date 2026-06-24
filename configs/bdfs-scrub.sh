#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# bdfs-scrub.sh - Scrub all BTRFS filesystems registered with bdfs
#
# Reads the list of mountpoints to scrub from /etc/bdfs/scrub.conf
# (one mountpoint per line, lines starting with # are comments).
# Falls back to scrubbing all currently mounted BTRFS filesystems
# when no config file is present.
#
# Notification: logs to systemd journal via systemd-cat.
# Optional email notification: set BDFS_NOTIFY_EMAIL in /etc/bdfs/bdfs.conf.

set -euo pipefail

SCRUB_CONF="${BDFS_SCRUB_CONF:-/etc/bdfs/scrub.conf}"
LOG_TAG="bdfs-scrub"
ERRORS=0

log()  { echo "$*" | systemd-cat -t "$LOG_TAG" -p info;  }
err()  { echo "$*" | systemd-cat -t "$LOG_TAG" -p err; ERRORS=$((ERRORS+1)); }

# Collect mountpoints
declare -a MOUNTS=()

if [[ -f "$SCRUB_CONF" ]]; then
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// }" ]] && continue
		MOUNTS+=("$line")
	done < "$SCRUB_CONF"
fi

# Fall back to all mounted BTRFS filesystems
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
	while IFS= read -r mnt; do
		[[ -n "$mnt" ]] && MOUNTS+=("$mnt")
	done < <(findmnt --real -t btrfs -lno TARGET 2>/dev/null || true)
fi

if [[ ${#MOUNTS[@]} -eq 0 ]]; then
	log "No BTRFS filesystems found to scrub."
	exit 0
fi

log "Starting scrub of ${#MOUNTS[@]} filesystem(s)."

for mnt in "${MOUNTS[@]}"; do
	if ! mountpoint -q "$mnt" 2>/dev/null; then
		err "Skipping $mnt: not a mountpoint"
		continue
	fi
	log "Scrubbing $mnt..."
	if btrfs scrub start -Bd "$mnt" 2>&1 | systemd-cat -t "$LOG_TAG"; then
		log "Scrub of $mnt completed."
	else
		err "Scrub of $mnt failed (exit $?)."
	fi
done

if [[ $ERRORS -gt 0 ]]; then
	log "Scrub finished with $ERRORS error(s)."
	exit 1
fi
log "All scrubs completed successfully."
