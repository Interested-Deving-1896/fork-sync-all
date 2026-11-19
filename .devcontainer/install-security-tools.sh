#!/usr/bin/env bash
# .devcontainer/install-security-tools.sh
# Installs dev-machine-guard (StepSecurity) into the devcontainer.
# Called from postCreateCommand — failures are non-fatal (tool is optional).

set -euo pipefail

info() { echo "[devcontainer/security] $*" >&2; }
warn() { echo "[devcontainer/security][warn] $*" >&2; }

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

# ── dev-machine-guard ─────────────────────────────────────────────────────────
if command -v dev-machine-guard &>/dev/null; then
  info "dev-machine-guard already installed: $(dev-machine-guard --version 2>/dev/null || echo 'unknown version')"
else
  info "installing dev-machine-guard..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm"   ;;
  esac

  # Fetch latest release tag
  LATEST=$(curl -sf "https://api.github.com/repos/step-security/dev-machine-guard/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")

  if [[ -z "$LATEST" ]]; then
    warn "could not resolve latest dev-machine-guard release — skipping"
  else
    DOWNLOAD_URL="https://github.com/step-security/dev-machine-guard/releases/download/${LATEST}/dev-machine-guard_${OS}_${ARCH}.tar.gz"
    TMP=$(mktemp -d)
    if curl -sfL "$DOWNLOAD_URL" | tar -xz -C "$TMP" 2>/dev/null; then
      mv "$TMP/dev-machine-guard" "$INSTALL_DIR/" 2>/dev/null || true
      chmod +x "$INSTALL_DIR/dev-machine-guard" 2>/dev/null || true
      info "installed dev-machine-guard ${LATEST} → ${INSTALL_DIR}/dev-machine-guard"
    else
      warn "download failed for ${DOWNLOAD_URL} — dev-machine-guard not installed"
    fi
    rm -rf "$TMP"
  fi
fi

# ── ratchet ───────────────────────────────────────────────────────────────────
if command -v ratchet &>/dev/null; then
  info "ratchet already installed: $(ratchet --version 2>/dev/null || echo 'unknown version')"
else
  info "installing ratchet..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
  esac

  LATEST=$(curl -sf "https://api.github.com/repos/sethvargo/ratchet/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null || echo "")

  if [[ -z "$LATEST" ]]; then
    warn "could not resolve latest ratchet release — skipping"
  else
    DOWNLOAD_URL="https://github.com/sethvargo/ratchet/releases/download/v${LATEST}/ratchet_${OS}_${ARCH}.tar.gz"
    TMP=$(mktemp -d)
    if curl -sfL "$DOWNLOAD_URL" | tar -xz -C "$TMP" 2>/dev/null; then
      mv "$TMP/ratchet" "$INSTALL_DIR/" 2>/dev/null || true
      chmod +x "$INSTALL_DIR/ratchet" 2>/dev/null || true
      info "installed ratchet ${LATEST} → ${INSTALL_DIR}/ratchet"
    else
      warn "download failed for ${DOWNLOAD_URL} — ratchet not installed"
    fi
    rm -rf "$TMP"
  fi
fi

info "security tools setup complete"
