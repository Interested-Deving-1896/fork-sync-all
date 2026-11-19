#!/usr/bin/env bash
# Run Tier 2 repo creation: armhf + riscv64 + s390x (3 × 35 = 105 repos).
# Resumes safely — create-arch-repos.py skips repos that already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

echo "=== Tier 2: armhf + riscv64 + s390x (105 repos, skips existing) ==="
echo "Started: $(date -u)"

python3 "$SCRIPT_DIR/create-arch-repos.py" --arch armhf riscv64 s390x

echo "Done: $(date -u)"
