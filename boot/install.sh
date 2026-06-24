#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# boot/install.sh - Install BDFS boot integration and maintenance components
#
# Usage:
#   sudo bash boot/install.sh [OPTIONS]
#
# Options:
#   --initramfs-tools   Force initramfs-tools backend
#   --dracut            Force dracut backend
#   --maintenance       Install scrub/balance systemd units only
#   --homed-check       Install homed-identity-check tool and units
#   --dry-run           Print actions without executing them
#   --help              Show this help

set -euo pipefail

DRY_RUN=0
INITRAMFS_SYSTEM=""
DO_BOOT=1
DO_MAINTENANCE=0
DO_HOMED=0

for arg in "$@"; do
	case "$arg" in
	--initramfs-tools) INITRAMFS_SYSTEM="initramfs-tools" ;;
	--dracut)          INITRAMFS_SYSTEM="dracut" ;;
	--maintenance)     DO_BOOT=0; DO_MAINTENANCE=1 ;;
	--homed-check)     DO_HOMED=1 ;;
	--dry-run)         DRY_RUN=1 ;;
	--help)
		sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
		exit 0
		;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "[dry-run] $*"
	else
		"$@"
	fi
}

# ── Maintenance units (scrub + balance) ──────────────────────────────────────

install_maintenance() {
	echo "Installing BDFS maintenance units (scrub + balance)..."

	run install -d /usr/lib/bdfs
	run install -m755 "$REPO_ROOT/configs/bdfs-scrub.sh"   /usr/lib/bdfs/bdfs-scrub.sh
	run install -m755 "$REPO_ROOT/configs/bdfs-balance.sh" /usr/lib/bdfs/bdfs-balance.sh

	run install -m644 "$REPO_ROOT/configs/bdfs-scrub.service"   /etc/systemd/system/bdfs-scrub.service
	run install -m644 "$REPO_ROOT/configs/bdfs-scrub.timer"     /etc/systemd/system/bdfs-scrub.timer
	run install -m644 "$REPO_ROOT/configs/bdfs-balance.service" /etc/systemd/system/bdfs-balance.service
	run install -m644 "$REPO_ROOT/configs/bdfs-balance.timer"   /etc/systemd/system/bdfs-balance.timer

	# Install genfstab script to libexec
	run install -m755 "$REPO_ROOT/tools/setup/bdfs-genfstab.sh" /usr/lib/bdfs/bdfs-genfstab.sh

	if [[ "$DRY_RUN" -eq 0 ]]; then
		systemctl daemon-reload
		systemctl enable --now bdfs-scrub.timer
		systemctl enable --now bdfs-balance.timer
		echo "Enabled bdfs-scrub.timer and bdfs-balance.timer"
	fi
}

# ── homed-identity-check ─────────────────────────────────────────────────────

install_homed() {
	echo "Installing homed-identity-check..."

	run install -d /usr/lib/bdfs
	run install -m755 \
		"$REPO_ROOT/tools/homed/homed-identity-check.sh" \
		/usr/lib/bdfs/homed-identity-check.sh

	run install -m644 \
		"$REPO_ROOT/tools/homed/homed-identity-check.service" \
		/etc/systemd/system/homed-identity-check.service
	run install -m644 \
		"$REPO_ROOT/tools/homed/homed-identity-check.timer" \
		/etc/systemd/system/homed-identity-check.timer
	run install -m644 \
		"$REPO_ROOT/tools/homed/homed-identity-check.path" \
		/etc/systemd/system/homed-identity-check.path

	if [[ "$DRY_RUN" -eq 0 ]]; then
		# Only activate if systemd-homed is present on this system
		if systemctl is-active --quiet systemd-homed 2>/dev/null || \
		   systemctl is-enabled --quiet systemd-homed 2>/dev/null; then
			systemctl daemon-reload
			systemctl enable --now homed-identity-check.path
			echo "Enabled homed-identity-check.path"
		else
			echo "systemd-homed not active — homed-identity-check units installed but not enabled."
			echo "Enable manually with: systemctl enable --now homed-identity-check.path"
		fi
	fi
}

# ── Boot integration ─────────────────────────────────────────────────────────

install_boot() {
	# Auto-detect initramfs system if not specified
	if [[ -z "$INITRAMFS_SYSTEM" ]]; then
		if command -v update-initramfs &>/dev/null; then
			INITRAMFS_SYSTEM="initramfs-tools"
		elif command -v dracut &>/dev/null; then
			INITRAMFS_SYSTEM="dracut"
		else
			echo "error: cannot detect initramfs system (install initramfs-tools or dracut)"
			exit 1
		fi
	fi

	echo "Installing BDFS boot integration (initramfs: $INITRAMFS_SYSTEM)..."

	run install -d /usr/lib/bdfs
	run install -m755 "$SCRIPT_DIR/bdfs-image-update" /usr/local/sbin/bdfs-image-update

	run install -m644 \
		"$SCRIPT_DIR/systemd-generator/bdfs-image-update.service" \
		/etc/systemd/system/bdfs-image-update.service
	run install -m644 \
		"$SCRIPT_DIR/systemd-generator/bdfs-image-update.timer" \
		/etc/systemd/system/bdfs-image-update.timer

	run install -d /etc/bdfs
	if [[ ! -f /etc/bdfs/boot.conf ]]; then
		run install -m644 "$REPO_ROOT/configs/boot.conf" /etc/bdfs/boot.conf
		echo "Installed /etc/bdfs/boot.conf — edit before rebooting"
	else
		echo "Skipping /etc/bdfs/boot.conf (already exists)"
	fi

	if [[ "$INITRAMFS_SYSTEM" == "initramfs-tools" ]]; then
		run install -m755 \
			"$SCRIPT_DIR/initramfs/hooks/bdfs" \
			/etc/initramfs-tools/hooks/bdfs
		run install -m755 \
			"$SCRIPT_DIR/initramfs/scripts/bdfs-root" \
			/etc/initramfs-tools/scripts/local-premount/bdfs-root
		echo "Installed initramfs-tools hook and script"
	elif [[ "$INITRAMFS_SYSTEM" == "dracut" ]]; then
		run install -d /usr/lib/dracut/modules.d/90bdfs
		run install -m755 \
			"$SCRIPT_DIR/dracut/module-setup.sh" \
			/usr/lib/dracut/modules.d/90bdfs/module-setup.sh
		run install -m755 \
			"$SCRIPT_DIR/dracut/bdfs-root.sh" \
			/usr/lib/dracut/modules.d/90bdfs/bdfs-root.sh
		echo "Installed dracut module 90bdfs"
	fi

	if [[ "$DRY_RUN" -eq 0 ]]; then
		echo "Rebuilding initramfs..."
		if [[ "$INITRAMFS_SYSTEM" == "initramfs-tools" ]]; then
			update-initramfs -u -k all
		else
			dracut --force --add bdfs
		fi
		systemctl daemon-reload
		systemctl enable bdfs-image-update.timer
		echo "Enabled bdfs-image-update.timer"
	fi

	echo ""
	echo "Next steps:"
	echo "  1. Edit /etc/bdfs/boot.conf"
	echo "  2. Add to kernel cmdline:"
	echo "       bdfs.root=/dev/sdXN bdfs.image=/images/system.dwarfs bdfs.upper=/dev/sdYN"
	echo "  3. Reboot"
}

# ── Main ─────────────────────────────────────────────────────────────────────

[[ "$DO_MAINTENANCE" -eq 1 ]] && install_maintenance
[[ "$DO_HOMED"       -eq 1 ]] && install_homed
[[ "$DO_BOOT"        -eq 1 ]] && { install_maintenance; install_boot; }

echo ""
echo "Installation complete."
