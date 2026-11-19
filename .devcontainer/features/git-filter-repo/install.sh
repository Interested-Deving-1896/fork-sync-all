#!/usr/bin/env bash
# Installs git-filter-repo at the version declared in devcontainer-feature.json.
# The VERSION variable is injected by the devcontainer feature runtime from
# the "version" option default (or caller override).
set -uo pipefail

VERSION="${VERSION:-2.47.0}"
INSTALL_DIR="/usr/local/bin"
URL="https://raw.githubusercontent.com/newren/git-filter-repo/v${VERSION}/git-filter-repo"

echo "Installing git-filter-repo v${VERSION} ..."
curl -fsSL "$URL" -o "${INSTALL_DIR}/git-filter-repo"
chmod +x "${INSTALL_DIR}/git-filter-repo"
echo "git-filter-repo $(git filter-repo --version 2>/dev/null || echo "v${VERSION}") installed."
