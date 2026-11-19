#!/usr/bin/env bash
# Run Tier 1 arm64 repo creation (31 repos remaining after amd64 done).
# Resumes safely — create-arch-repos.py skips repos that already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

echo "=== Tier 1: arm64 (35 repos, skips existing) ==="
echo "Started: $(date -u)"

python3 "$SCRIPT_DIR/create-arch-repos.py" --arch arm64

echo "Done: $(date -u)"
