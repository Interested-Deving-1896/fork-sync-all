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

# Tag safety: preserve existing destination tags, fail closed on inspection,
# and avoid retries for a tag push that races with destination changes.
assert_contains "git ls-remote --refs dest 'refs/tags/*'"
assert_contains 'Tag ${tag} already exists on destination; preserving destination tag'
assert_contains 'Could not inspect destination tags'
assert_contains 'safe_tag_refspecs+=("refs/tags/${tag}:refs/tags/${tag}")'
assert_contains '_git_push_retry dest "${branch_refspecs[@]}"'
assert_contains '_git_push_once dest "${safe_tag_refspecs[@]}"'
if grep -Fq -- '_git_push_retry dest "${safe_tag_refspecs[@]}"' "$SCRIPT"; then
  printf 'FAIL: tag pushes must not use the retry helper\n' >&2
  exit 1
fi

# Disk guard: validate configuration and stop safely before clone if space
# cannot be measured or is below the configured minimum.
assert_contains 'MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-1024}"'
assert_contains 'if ! tmpdir=$(mktemp -d); then'
assert_contains 'Could not create temporary workspace for ${repo}'
assert_contains 'free_mb=$(_available_disk_mb "$tmpdir")'
if grep -Fq -- 'trap "rm -rf --' "$SCRIPT"; then
  printf 'FAIL: per-repo cleanup must not leave a RETURN trap installed\n' >&2
  exit 1
fi
assert_contains 'rm -rf -- "$tmpdir"'
assert_contains 'Available disk before clone: ${free_mb} MB'
assert_contains 'Disk-space guard tripped before cloning ${repo}'
assert_contains 'Available disk after clone: ${free_mb} MB'
assert_contains 'Disk-space guard tripped after cloning ${repo}'
assert_contains 'Could not determine free disk space after cloning ${repo}'
assert_contains 'DISK_GUARD_TRIPPED=true'
assert_contains 'inventory may be incomplete'
assert_contains 'Skipping second sync leg because the disk-space guard stopped the first leg'

# Bare clones expose local heads refs, not origin/* remote-tracking refs.
assert_contains "git for-each-ref --format='%(refname:strip=2)' refs/heads/"
if grep -Fq -- 'git branch -r' "$SCRIPT"; then
  printf 'FAIL: bare-clone branch discovery must not depend on remote-tracking refs\\n' >&2
  exit 1
fi

# Branches and tags remain separate in dry-run and real push paths.
assert_contains 'would push ${#branch_refspecs[@]} branch ref(s) and ${#safe_tag_refspecs[@]} new tag(s)'
assert_contains 'if [[ "$DRY_RUN" == "true" ]]; then'

# Add a behavioral harness using local bare repositories and stubbed df.
bash "$(dirname "${BASH_SOURCE[0]}")/test-git-platform-sync-post-clone-disk.sh"

printf 'PASS: integrated git-platform-sync tag and disk guard checks\n'
