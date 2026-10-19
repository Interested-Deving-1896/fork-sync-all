#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/git-platform-sync.sh"

assert_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    printf 'FAIL: expected script to contain: %s\n' "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  if grep -Fq -- "$needle" "$SCRIPT"; then
    printf 'FAIL: unexpected script content: %s\n' "$needle" >&2
    exit 1
  fi
}

# Existing destination tags must be preserved, not pushed or force-updated.
assert_contains "git ls-remote --refs dest 'refs/tags/*'"
assert_contains 'Tag ${tag} already exists on destination; preserving destination tag'
assert_contains 'refusing to push tags'
assert_contains 'safe_tag_refspecs+=("refs/tags/${tag}:refs/tags/${tag}")'

# Branches and tags must be pushed independently so tag conflicts do not block branches.
assert_contains '_git_push_retry dest "${branch_refspecs[@]}"'
assert_contains '_git_push_retry dest "${safe_tag_refspecs[@]}"'

# A dry run must report only new tag pushes and never perform a push.
assert_contains 'if [[ "$DRY_RUN" == "true" ]]; then'
assert_contains 'would push ${#branch_refspecs[@]} branch ref(s) and ${#safe_tag_refspecs[@]} new tag(s)'

printf 'PASS: git-platform-sync tag safety regression checks\n'
