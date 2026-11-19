#!/usr/bin/env bash
# Prepare Fork-Sync-All dependencies in a Codex Cloud environment.

set -euo pipefail

info() { echo "[codex-cloud-install] $*" >&2; }
warn() { echo "[codex-cloud-install][warn] $*" >&2; }

info "Creating the repository Python environment"
python3 -m venv .venv
.venv/bin/python -m pip install --quiet 'PyYAML>=6,<7' 'pytest>=8,<10'

if ! command -v mdbook >/dev/null || [[ "$(mdbook --version)" != "mdbook v0.4.40" ]]; then
  command -v cargo >/dev/null || {
    warn "cargo is required to install mdBook 0.4.40"
    exit 1
  }
  info "Installing mdBook 0.4.40"
  cargo install mdbook --version 0.4.40 --locked
fi

if ! command -v shell2http >/dev/null; then
  command -v go >/dev/null || {
    warn "Go is required to install shell2http"
    exit 1
  }
  info "Installing shell2http"
  go install github.com/msoap/shell2http@latest
fi

info "Installing optional environment security tools"
bash .devcontainer/install-security-tools.sh

info "Validating the portable repository configuration"
.venv/bin/python scripts/validate-template-config.py
.venv/bin/python scripts/agent-badge-registry.py validate
.venv/bin/python scripts/readme-subsystem.py validate
.venv/bin/python scripts/readme-subsystem.py lock --check
.venv/bin/python scripts/validate-live-chain-manifest.py

info "Codex Cloud installation complete"
