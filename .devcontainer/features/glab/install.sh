#!/usr/bin/env bash
# Installs glab (GitLab CLI) at the version declared in devcontainer-feature.json.
set -euo pipefail

VERSION="${VERSION:-1.97.0}"
URL="https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/glab/${VERSION}/glab_${VERSION}_linux_amd64.deb"
DEB="/tmp/glab_${VERSION}_linux_amd64.deb"

echo "Installing glab v${VERSION} ..."
curl -fsSL "${URL}" -o "${DEB}"
dpkg -i "${DEB}"
rm -f "${DEB}"
echo "glab $(glab --version) installed."
