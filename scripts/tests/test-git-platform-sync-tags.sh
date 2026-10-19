#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/git-platform-sync.sh"

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
assert_contains 'Tag ${tag} already exists with matching object ID; preserving destination tag'
assert_contains 'Tag conflict for ${tag}: source object ${source_oid:-unknown}, destination object ${existing_tag_ids[$tag]}; preserving destination tag'
assert_contains 'local -A existing_tag_ids=()'
assert_contains 'source_oid=$(git rev-parse "refs/tags/$tag" 2>/dev/null)'
assert_contains '(( tag_conflicts > 0 )) && rc=1'
assert_contains 'tag_inspection_failed=true'
assert_contains 'tag inspection failed=${tag_inspection_failed}'
assert_contains 'refusing to push tags'
assert_contains 'safe_tag_refspecs+=("refs/tags/${tag}:refs/tags/${tag}")'

# Branches and tags must be pushed independently so tag conflicts do not block branches.
assert_contains '_git_push_retry dest "${branch_refspecs[@]}"'
assert_contains '_git_push_once dest "${safe_tag_refspecs[@]}"'
assert_contains 'not retrying (destination may have changed after preflight)'
if grep -Fq -- '_git_push_retry dest "${safe_tag_refspecs[@]}"' "$SCRIPT"; then
  printf 'FAIL: tag pushes must not use the retry helper\n' >&2
  exit 1
fi

# A dry run must report only new tag pushes and never perform a push.
assert_contains 'if [[ "$DRY_RUN" == "true" ]]; then'
assert_contains 'would push ${#branch_refspecs[@]} branch ref(s) and ${#safe_tag_refspecs[@]} new tag(s)'

printf 'PASS: git-platform-sync tag safety regression checks\n'
