#!/usr/bin/env bash
# cleanup-redundant-base-repos.sh — delete repos superseded by the new model
#
# Deletes:
#   devuan-{arch}-kernel-base  × 10  (now patchset branches in debian-{arch}-kernel-base)
#   ubuntu-{arch}-kernel-base  × 10  (same)
#   {arch}-deb-linux-kernel-base × 10 (hub repos folded into debian-{arch}-kernel-base)
#   debian-i686-kernel-base    × 1   (wrong name — correct is debian-i386-kernel-base)
#
# All of these are currently empty (no content was ever pushed).
# Safe to delete without data loss.
#
# Usage:
#   ./cleanup-redundant-base-repos.sh
#   ./cleanup-redundant-base-repos.sh --dry-run
set -euo pipefail

ORG="Interested-Deving-1896"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

[[ -z "$GH_TOKEN" ]] && { echo "ERROR: GH_TOKEN not set" >&2; exit 1; }

ARCHS=(amd64 arm64 armhf riscv64 s390x armel ppc64el mips64el loong64 i686)

REPOS_TO_DELETE=()

# devuan-{arch}-kernel-base (10)
for arch in "${ARCHS[@]}"; do
  REPOS_TO_DELETE+=("devuan-${arch}-kernel-base")
done

# ubuntu-{arch}-kernel-base (10)
for arch in "${ARCHS[@]}"; do
  REPOS_TO_DELETE+=("ubuntu-${arch}-kernel-base")
done

# {arch}-deb-linux-kernel-base (10)
for arch in "${ARCHS[@]}"; do
  REPOS_TO_DELETE+=("${arch}-deb-linux-kernel-base")
done

# Wrong-named i686 repo (correct is i386)
REPOS_TO_DELETE+=("debian-i686-kernel-base")

echo "=== Delete ${#REPOS_TO_DELETE[@]} redundant kernel-base repos ==="
echo "Dry-run: $DRY_RUN"
echo "Started: $(date -u)"
echo ""

deleted=0; skipped=0; failed=0

for repo in "${REPOS_TO_DELETE[@]}"; do
  if $DRY_RUN; then
    echo "  [dry-run] delete $repo"
    continue
  fi

  # Verify repo is empty before deleting
  has_content=$(git ls-remote \
    "https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${repo}.git" \
    HEAD 2>/dev/null | wc -l)

  if [[ "$has_content" -gt 0 ]]; then
    echo "  [skip] $repo has content — not deleting"
    skipped=$((skipped+1))
    continue
  fi

  if gh api -X DELETE "repos/${ORG}/${repo}" 2>/dev/null; then
    echo "  ✓ deleted $repo"
    deleted=$((deleted+1))
  else
    echo "  ✗ failed to delete $repo"
    failed=$((failed+1))
  fi
  sleep 0.5
done

echo ""
echo "=== Done: $deleted deleted, $skipped skipped (had content), $failed failed. $(date -u) ==="
