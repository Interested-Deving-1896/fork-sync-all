#!/usr/bin/env bash
#
# services/sync-in/install.sh — install the sync-in-server binary
#
# Called by devcontainer postCreateCommand (path B) and the automations
# 'Install Sync-in Server' task (path C). Skips silently if the binary
# is already present and up to date.
#
# Environment variables:
#   SYNC_IN_VERSION    — version to install (default: latest)
#   SYNC_IN_INSTALL_DIR — install directory (default: ~/.local/bin)
#   FORCE              — set to "true" to reinstall even if already present

set -uo pipefail

INSTALL_VERSION="${SYNC_IN_VERSION:-latest}"
INSTALL_DIR="${SYNC_IN_INSTALL_DIR:-${HOME}/.local/bin}"
FORCE="${FORCE:-false}"

log()  { echo "[sync-in/install] $*" >&2; }
warn() { echo "[sync-in/install][warn] $*" >&2; }
ok()   { echo "[sync-in/install] ✓ $*" >&2; }

# ── Skip if already installed (unless forced) ─────────────────────────────────
if [[ "$FORCE" != "true" ]]; then
  for candidate in "/usr/local/bin/sync-in-server" "${INSTALL_DIR}/sync-in-server" \
                   "$(command -v sync-in-server 2>/dev/null || true)"; do
    if [[ -x "$candidate" ]]; then
      ok "sync-in-server already installed at ${candidate} — skipping."
      ok "Set FORCE=true to reinstall."
      exit 0
    fi
  done
fi

# ── Resolve architecture ──────────────────────────────────────────────────────
arch=$(uname -m)
case "$arch" in
  x86_64)  arch_label="amd64" ;;
  aarch64) arch_label="arm64" ;;
  armv7l)  arch_label="armv7" ;;
  *)       arch_label="amd64" ;;
esac

# ── Resolve version tag ───────────────────────────────────────────────────────
tag="$INSTALL_VERSION"
if [[ "$tag" == "latest" ]]; then
  log "Resolving latest release from github.com/Sync-in/server..."
  tag=$(curl -sf "https://api.github.com/repos/Sync-in/server/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")
  if [[ -z "$tag" ]]; then
    warn "Could not resolve latest release. Check https://github.com/Sync-in/server/releases"
    warn "Set SYNC_IN_VERSION=vX.Y.Z to pin a specific version."
    exit 0  # Non-fatal: service will self-install at first start
  fi
fi

ver="${tag#v}"
log "Installing sync-in-server ${tag} (${arch_label}) → ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

tmp=$(mktemp /tmp/sync-in.XXXXXX)
installed=false

for asset_name in \
    "sync-in-server_${ver}_linux_${arch_label}.tar.gz" \
    "sync-in-server-linux-${arch_label}.tar.gz" \
    "sync-in_${ver}_linux_${arch_label}.tar.gz" \
    "server-linux-${arch_label}" \
    "sync-in-server-linux-${arch_label}"; do

  url="https://github.com/Sync-in/server/releases/download/${tag}/${asset_name}"
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    if file "$tmp" 2>/dev/null | grep -q "gzip\|tar"; then
      extract_dir=$(mktemp -d /tmp/sync-in-extract.XXXXXX)
      tar -xzf "$tmp" -C "$extract_dir" 2>/dev/null || true
      bin=$(find "$extract_dir" -type f \( -name "sync-in-server" -o -name "sync-in" \) 2>/dev/null | head -1)
      if [[ -n "$bin" ]]; then
        install -m 0755 "$bin" "${INSTALL_DIR}/sync-in-server"
        rm -rf "$extract_dir"
        installed=true
        break
      fi
      rm -rf "$extract_dir"
    else
      install -m 0755 "$tmp" "${INSTALL_DIR}/sync-in-server"
      installed=true
      break
    fi
  fi
done

rm -f "$tmp"

if [[ "$installed" == "true" ]]; then
  ok "sync-in-server ${tag} installed at ${INSTALL_DIR}/sync-in-server"
else
  warn "No matching release asset found for ${tag}/${arch_label}."
  warn "The service will attempt self-install at first start."
  exit 0  # Non-fatal
fi
