#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# homed-identity-check.sh - Verify and repair systemd-homed identity files
#
# Checks that the host identity (/var/lib/systemd/home/<user>.identity) and
# the embedded identity (<homedir>/.identity) are in sync.  When they diverge
# (e.g. after a systemd upgrade that changes the signing key), re-signs the
# embedded identity and forces a homectl update to resynchronise.
#
# Configuration (environment variables or /etc/bdfs/homed.conf):
#   HOMED_USER        Username to check (default: first active homed user)
#   HOMED_PRIVATE_KEY Path to homed private key
#                     (default: /var/lib/systemd/home/local.private)
#   HOMED_LOG         Log file path (default: /var/log/bdfs-homed-check.log)
#
# Requirements: systemd-homed, python3, cryptography (pip install cryptography)
#
# This script is distro-agnostic.  It does not assume any package manager,
# desktop environment, or bootloader.  The only distro-specific element is
# the Python cryptography library — install it via your package manager:
#   Debian/Ubuntu: apt install python3-cryptography
#   Fedora/RHEL:   dnf install python3-cryptography
#   Arch:          pacman -S python-cryptography
#   Alpine:        apk add py3-cryptography

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

CONF_FILE="${BDFS_HOMED_CONF:-/etc/bdfs/homed.conf}"
if [[ -f "$CONF_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONF_FILE"
fi

PRIVATE_KEY="${HOMED_PRIVATE_KEY:-/var/lib/systemd/home/local.private}"
HOMED_LOG="${HOMED_LOG:-/var/log/bdfs-homed-check.log}"

# ── Prerequisite: systemd-homed must be active ────────────────────────────────

if ! systemctl is-active --quiet systemd-homed 2>/dev/null; then
	echo "systemd-homed is not active — nothing to do." | \
		systemd-cat -t homed-identity-check -p info
	exit 0
fi

# ── Resolve target user ───────────────────────────────────────────────────────

if [[ -z "${HOMED_USER:-}" ]]; then
	# Find the first user managed by homed
	HOMED_USER=$(homectl list --no-legend 2>/dev/null | awk 'NR==1{print $1}')
	if [[ -z "$HOMED_USER" ]]; then
		echo "No homed users found." | \
			systemd-cat -t homed-identity-check -p info
		exit 0
	fi
fi

# ── Logging ───────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$HOMED_LOG")"
log()     { printf "[%s] %s\n"       "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$HOMED_LOG"; }
log_err() { printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$HOMED_LOG" >&2; }

log "=== homed-identity-check started (user: $HOMED_USER) ==="

HOST_IDENTITY="/var/lib/systemd/home/${HOMED_USER}.identity"
HOMEDIR=$(homectl inspect "$HOMED_USER" 2>/dev/null | awk '/Home Directory:/{print $NF}')
EMBEDDED_IDENTITY="${HOMEDIR}/.identity"

# ── Prerequisite checks ───────────────────────────────────────────────────────

if [[ ! -f "$HOST_IDENTITY" ]]; then
	log_err "Host identity not found: $HOST_IDENTITY"
	exit 1
fi
if [[ ! -f "$PRIVATE_KEY" ]]; then
	log_err "homed private key not found: $PRIVATE_KEY"
	exit 1
fi

# ── Compare timestamps ────────────────────────────────────────────────────────

NEEDS_RESIGN=false

if [[ ! -f "$EMBEDDED_IDENTITY" ]]; then
	log "Embedded identity missing — will re-sign."
	NEEDS_RESIGN=true
else
	HOST_TS=$(python3 -c \
		"import json; d=json.load(open('$HOST_IDENTITY')); \
		 print(d.get('lastChangeUSec', 0))" 2>/dev/null || echo "0")
	EMB_TS=$(python3 -c \
		"import json; d=json.load(open('$EMBEDDED_IDENTITY')); \
		 print(d.get('lastChangeUSec', 0))" 2>/dev/null || echo "-1")

	log "Host lastChangeUSec: $HOST_TS"
	log "Embedded lastChangeUSec: $EMB_TS"

	if [[ "$HOST_TS" == "$EMB_TS" ]]; then
		log "Identity files are in sync."
		log "=== check completed OK ==="
		exit 0
	fi
	log "Timestamps differ — re-signing embedded identity."
	NEEDS_RESIGN=true
fi

# ── Ownership repair (upstream systemd bug #38941) ────────────────────────────

if [[ "$NEEDS_RESIGN" == "true" && -f "$EMBEDDED_IDENTITY" ]]; then
	HOMEDIR_OWNER=$(stat -c '%U:%G' "$HOMEDIR" 2>/dev/null || echo "unknown")
	IDENTITY_OWNER=$(stat -c '%U:%G' "$EMBEDDED_IDENTITY" 2>/dev/null || echo "unknown")
	log "Checking ownership: homedir=$HOMEDIR_OWNER identity=$IDENTITY_OWNER"

	FIXED=false
	for path in "$HOMEDIR" "$EMBEDDED_IDENTITY"; do
		owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo "unknown")
		if [[ "$owner" != "nobody:nobody" && "$owner" != "nobody:nogroup" ]]; then
			log "Fixing ownership of $path → nobody:nobody"
			chown nobody:nobody "$path" && FIXED=true
		fi
	done

	if [[ "$FIXED" == "true" ]]; then
		systemctl restart systemd-homed
		sleep 2
		STATE=$(homectl inspect "$HOMED_USER" 2>/dev/null | awk '/State:/{print $2}')
		log "Home state after ownership fix: $STATE"
		if [[ "$STATE" == "active" ]]; then
			log "Ownership fix sufficient — identity accessible."
			NEEDS_RESIGN=false
		fi
	fi
fi

# ── Re-sign embedded identity ─────────────────────────────────────────────────

if [[ "$NEEDS_RESIGN" == "true" ]]; then
	log "Re-signing embedded .identity..."

	python3 - <<PYEOF >> "$HOMED_LOG" 2>&1
import json, base64, sys, os, stat as stat_mod
from cryptography.hazmat.primitives.serialization import (
    load_pem_private_key, Encoding, PublicFormat, load_pem_public_key
)

HOST_IDENTITY   = "$HOST_IDENTITY"
EMBEDDED_IDENTITY = "$EMBEDDED_IDENTITY"
PRIVATE_KEY     = "$PRIVATE_KEY"

with open(PRIVATE_KEY, "rb") as f:
    private_key = load_pem_private_key(f.read(), password=None)

with open(HOST_IDENTITY, "r") as f:
    identity = json.load(f)

# Embedded identity excludes binding, status, and signature fields
exclude = {"signature", "binding", "status"}
embedded = {k: v for k, v in identity.items() if k not in exclude}

# systemd signs JSON in compact sorted form
to_sign = json.dumps(embedded, sort_keys=True, separators=(',', ':')).encode()
signature = private_key.sign(to_sign)
sig_b64 = base64.b64encode(signature).decode()

pub_pem = private_key.public_key().public_bytes(
    Encoding.PEM, PublicFormat.SubjectPublicKeyInfo
).decode()

# Verify before writing
pub_key = load_pem_public_key(pub_pem.encode())
try:
    pub_key.verify(base64.b64decode(sig_b64), to_sign)
except Exception as e:
    print(f"FATAL: signature verification failed: {e}", file=sys.stderr)
    sys.exit(1)

embedded["signature"] = [{"data": sig_b64, "key": pub_pem}]

with open(EMBEDDED_IDENTITY, "w") as f:
    json.dump(embedded, f, indent="\t")
    f.write("\n")

os.chmod(EMBEDDED_IDENTITY, stat_mod.S_IRUSR | stat_mod.S_IWUSR)  # 0600
print("Embedded .identity re-signed successfully.")
PYEOF

	PYTHON_EXIT=$?
	if [[ $PYTHON_EXIT -ne 0 ]]; then
		log_err "Re-sign failed (exit $PYTHON_EXIT)"
		exit 1
	fi

	log "Re-sign successful. Restarting systemd-homed..."
	systemctl restart systemd-homed
	sleep 2

	STATE=$(homectl inspect "$HOMED_USER" 2>/dev/null | awk '/State:/{print $2}')
	log "Home state after restart: $STATE"

	if [[ "$STATE" == "active" ]]; then
		REAL_NAME=$(python3 -c \
			"import json; d=json.load(open('$HOST_IDENTITY')); \
			 print(d.get('realName',''))" 2>/dev/null || echo "")
		if homectl update "$HOMED_USER" \
			${REAL_NAME:+--real-name="$REAL_NAME"} \
			>> "$HOMED_LOG" 2>&1; then
			log "homectl update succeeded — identity files in sync."
		else
			log_err "homectl update failed — manual intervention may be required."
			exit 1
		fi
	else
		log "Home not active — skipping homectl update."
		log "Run manually: homectl update $HOMED_USER"
	fi
fi

log "=== check completed ==="
exit 0
