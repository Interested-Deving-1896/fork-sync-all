#!/usr/bin/env bash
# Basic offline tests for audit-workflow-freshness.sh argument and dependency handling.
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/audit-workflow-freshness.sh"
# Missing repository should fail with usage, before any API call.
if output=$(bash "$SCRIPT" 2>&1); then
  echo "expected missing repository to fail" >&2
  exit 1
fi
grep -q 'usage:' <<<"$output"

# Invalid threshold should fail early.
if output=$(env PATH="$PATH" "$SCRIPT" owner/repo invalid 2>&1); then
  echo "expected invalid threshold to fail" >&2
  exit 1
fi
grep -q 'stale-days must be a non-negative integer' <<<"$output"

# Invalid repository syntax should fail before invoking gh.
if output=$(env PATH="$PATH" "$SCRIPT" "owner name/repo" 2>&1); then
  echo "expected malformed repository to fail" >&2
  exit 1
fi
grep -q 'repository must be in owner/name form' <<<"$output"

echo "workflow freshness audit argument tests passed"
