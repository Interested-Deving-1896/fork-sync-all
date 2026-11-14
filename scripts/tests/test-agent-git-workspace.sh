#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/agent-git-workspace.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() {
  if "$@" >"$tmp/out" 2>"$tmp/err"; then
    fail "expected failure: $*"
  fi
}

expect_fail bash "$SCRIPT" clone
grep -q 'clone requires OWNER/REPO' "$tmp/err" || fail "missing clone argument validation"
expect_fail bash "$SCRIPT" clone '../owner/repo' "$tmp/checkout"
grep -q 'expected OWNER/REPO' "$tmp/err" || fail "invalid repo coordinate accepted"
expect_fail bash "$SCRIPT" fetch "$tmp/not-a-repo"
grep -q 'not a Git worktree' "$tmp/err" || fail "fetch accepted a non-repository path"
expect_fail bash "$SCRIPT" status "$tmp/not-a-repo"
expect_fail bash "$SCRIPT" diff "$tmp/not-a-repo"
expect_fail bash "$SCRIPT" fork owner/repo
grep -q 'remote write' "$tmp/err" || fail "fork command not gated by explicit confirmation"

mkdir "$tmp/existing"
expect_fail bash "$SCRIPT" clone owner/repo "$tmp/existing"
grep -q 'target already exists' "$tmp/err" || fail "clone accepted existing target"

printf 'PASS: agent Git workspace argument and safety checks\n'
