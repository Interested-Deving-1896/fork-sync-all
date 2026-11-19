#!/usr/bin/env bash
# Installs the Sync-in server binary from github.com/Sync-in/server releases.
# Runs inside the devcontainer build context as root.
set -uo pipefail

VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_LABEL="amd64" ;;
  aarch64) ARCH_LABEL="arm64" ;;
  armv7l)  ARCH_LABEL="armv7" ;;
  *)       ARCH_LABEL="amd64" ;;
esac

info() { echo "==> [sync-in-server] $*"; }
warn() { echo "==> [sync-in-server][warn] $*" >&2; }
ok()   { echo "    ✓ $*"; }

# ── Ensure base deps ──────────────────────────────────────────────────────────
apt-get update -qq 2>/dev/null || true
apt-get install -y --no-install-recommends curl ca-certificates 2>/dev/null || true

# ── Resolve version ───────────────────────────────────────────────────────────
info "Resolving sync-in-server version (requested: ${VERSION})..."
if [[ "$VERSION" == "latest" ]]; then
  TAG=$(curl -sf "https://api.github.com/repos/Sync-in/server/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")
  if [[ -z "$TAG" ]]; then
    warn "Could not resolve latest release from GitHub API — binary not installed."
    warn "The sync-in-server service will self-install at first start via services/sync-in/start.sh."
    exit 0
  fi
else
  TAG="$VERSION"
fi

VER="${TAG#v}"
info "Installing sync-in-server ${TAG} (${ARCH_LABEL})..."

# ── Try release asset patterns ────────────────────────────────────────────────
# Sync-in/server may not exist yet or may use different asset naming.
# Try common patterns; fall through gracefully if none work.
INSTALLED=false
TMP=$(mktemp /tmp/sync-in.XXXXXX)

for asset_name in \
    "sync-in-server_${VER}_linux_${ARCH_LABEL}.tar.gz" \
    "sync-in-server-linux-${ARCH_LABEL}.tar.gz" \
    "sync-in_${VER}_linux_${ARCH_LABEL}.tar.gz" \
    "server-linux-${ARCH_LABEL}" \
    "sync-in-server-linux-${ARCH_LABEL}"; do

  URL="https://github.com/Sync-in/server/releases/download/${TAG}/${asset_name}"
  if curl -fsSL "$URL" -o "$TMP" 2>/dev/null; then
    if file "$TMP" 2>/dev/null | grep -q "gzip\|tar"; then
      # Tarball — extract binary
      mkdir -p /tmp/sync-in-extract
      tar -xzf "$TMP" -C /tmp/sync-in-extract 2>/dev/null || true
      BIN=$(find /tmp/sync-in-extract -type f \( -name "sync-in-server" -o -name "sync-in" \) 2>/dev/null | head -1)
      if [[ -n "$BIN" ]]; then
        install -m 0755 "$BIN" "${INSTALL_DIR}/sync-in-server"
        rm -rf /tmp/sync-in-extract
        INSTALLED=true
        break
      fi
      rm -rf /tmp/sync-in-extract
    else
      # Raw binary
      install -m 0755 "$TMP" "${INSTALL_DIR}/sync-in-server"
      INSTALLED=true
      break
    fi
  fi
done

rm -f "$TMP"

if [[ "$INSTALLED" == "true" ]]; then
  ok "sync-in-server installed at ${INSTALL_DIR}/sync-in-server"
  if command -v sync-in-server >/dev/null 2>&1; then
    ver=$(sync-in-server --version 2>/dev/null | head -1 || echo "${TAG}")
    ok "version: ${ver}"
  fi
else
  warn "No release asset matched for ${TAG}/${ARCH_LABEL}."
  warn "The sync-in-server service will self-install at first start via services/sync-in/start.sh."
fi
