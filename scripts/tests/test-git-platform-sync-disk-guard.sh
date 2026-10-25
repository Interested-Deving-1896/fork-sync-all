#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/git-platform-sync.sh"
assert_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    printf "FAIL: expected script to contain: %s\n" "$needle" >&2
    exit 1
  fi
}
assert_contains 'MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-1024}"'
assert_contains 'free_mb=$(_available_disk_mb "$tmpdir")'
assert_contains 'Available disk before clone: ${free_mb} MB'
assert_contains 'Disk-space guard tripped before cloning ${repo}'
assert_contains 'DISK_GUARD_TRIPPED=true'
assert_contains 'inventory may be incomplete'
assert_contains 'Skipping second sync leg because the disk-space guard stopped the first leg'
printf "PASS: git-platform-sync disk guard regression checks\n"
