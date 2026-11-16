#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/merge-to-monorepo.sh"
workflow="${repo_root}/.github/workflows/merge-to-monorepo.yml"

fail() { echo "[merge-to-monorepo-safety][FAIL] $*" >&2; exit 1; }
pass() { echo "[merge-to-monorepo-safety][PASS] $*"; }

bash -n "$script" || fail "importer has a Bash syntax error"
pass "Bash syntax"

grep -Fq 'CONFIRM_IMPORT' "$script" || fail "explicit import confirmation gate missing"
grep -Fq 'MONOREPO_URL must identify an existing destination repository' "$script" || fail "existing destination guard missing"
grep -Fq 'credential-free HTTPS GitHub repository URL' "$script" || fail "destination URL validation missing"
grep -Fq 'BRANCH_MAP is not valid JSON' "$script" || fail "malformed branch maps are not rejected"
grep -Fq 'BRANCH_MAP must be a JSON object' "$script" || fail "non-object branch maps are not rejected"
if grep -Fq '|| echo "$MONOREPO_BRANCH"' "$script"; then
  fail "invalid branch maps can still silently fall back to the default branch"
fi
grep -Fq 'set -euo pipefail' "$script" || fail "strict shell error handling missing"
grep -Fq 'History rewrite failed' "$script" || fail "history rewrite failure is not propagated"
grep -Fq 'refusing to push a partial monorepo' "$script" || fail "partial imports can still be published"
grep -Fq 'Each REPOS line must contain exactly one source URL' "$script" || fail "strict source manifest parser missing"
grep -Fq 'MONOREPO_URL' "$workflow" || fail "workflow destination URL input missing"

if grep -Fq '/orgs/${MONOREPO_OWNER}/repos' "$script"; then
  fail "unsafe organization-only repository auto-creation remains enabled"
fi
if grep -Eq 'git .*push.*--force|push .*--force|--force-with-lease' "$script"; then
  fail "force-push behavior remains enabled"
fi
if grep -Fq 'strategy ours' "$script"; then
  fail "silent ours-strategy conflict resolution remains enabled"
fi

pass "confirmation, destination, parsing, failure propagation, and no-force guards"
