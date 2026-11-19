#!/usr/bin/env bash
# Run Tier 3 repo creation: armel + ppc64el + mips64el + loong64 + i686
# (5 × 35 = 175 repos). Resumes safely — skips repos that already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

echo "=== Tier 3: armel + ppc64el + mips64el + loong64 + i686 (175 repos, skips existing) ==="
echo "Started: $(date -u)"

python3 "$SCRIPT_DIR/create-arch-repos.py" --arch armel ppc64el mips64el loong64 i686

echo "Done: $(date -u)"
