#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_GIT="$(command -v git)"
REAL_MKTEMP="$(command -v mktemp)"
TEST_ROOT="$($REAL_MKTEMP -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/scripts/includes"
cp "$ROOT/scripts/git-platform-sync.sh" "$TEST_ROOT/scripts/git-platform-sync.sh"

# Stub only the platform adapter and disk probe; real local Git repositories
# make clone/ref/push behavior observable without network or credentials.
cat > "$TEST_ROOT/scripts/includes/platform-adapter.sh" <<'ADAPTER'
pa_init() { :; }
pa_clone_url() { printf '%s/%s.git\n' "$FIXTURE_ROOT" "$1"; }
pa_push_url() { printf '%s/%s.git\n' "$FIXTURE_ROOT" "$1"; }
pa_create_repo() { :; }
pa_list_repos() { printf 'fixture\n'; }
pa_repo_exists() { return 0; }
ADAPTER
cat > "$TEST_ROOT/scripts/includes/budget.sh" <<'BUDGET'
budget_init() { :; }
budget_check() { return 0; }
BUDGET
cat > "$TEST_ROOT/bin/df" <<'DF'
#!/usr/bin/env bash
set -euo pipefail
count_file="$FIXTURE_ROOT/df-count"
count=0
[[ -f "$count_file" ]] && read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [[ "$count" -eq 1 ]]; then
  printf '/dev/test 5000 100 4900 2%% /tmp\n'
else
  case "${DISK_AFTER_CLONE:-low}" in
    low) printf '/dev/test 5000 4990 10 99%% /tmp\n' ;;
    unknown) printf '/dev/test 5000 5000 not-a-number 100%% /tmp\n' ;;
    *) printf '/dev/test 5000 100 4900 2%% /tmp\n' ;;
  esac
fi
DF
cat > "$TEST_ROOT/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "push" ]]; then
  printf 'push\n' >> "$FIXTURE_ROOT/git-actions.log"
elif [[ "${1:-}" == "clone" ]]; then
  printf 'clone\n' >> "$FIXTURE_ROOT/git-actions.log"
fi
exec "$REAL_GIT" "$@"
GIT
chmod +x "$TEST_ROOT/bin/df" "$TEST_ROOT/bin/git"

# Build a tiny source repository and an empty destination; all URLs are local.
export FIXTURE_ROOT="$TEST_ROOT/fixtures"
mkdir -p "$FIXTURE_ROOT"
"$REAL_GIT" init --bare -q "$FIXTURE_ROOT/source.git"
"$REAL_GIT" init -q "$TEST_ROOT/work"
"$REAL_GIT" -C "$TEST_ROOT/work" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m fixture >/dev/null
"$REAL_GIT" -C "$TEST_ROOT/work" branch -M main
"$REAL_GIT" -C "$TEST_ROOT/work" remote add origin "$FIXTURE_ROOT/source.git"
"$REAL_GIT" -C "$TEST_ROOT/work" push -q origin main
"$REAL_GIT" init --bare -q "$FIXTURE_ROOT/dest.git"

run_case() {
  local mode="$1" expected="$2"
  rm -f "$FIXTURE_ROOT/df-count" "$FIXTURE_ROOT/git-actions.log"
  set +e
  PATH="$TEST_ROOT/bin:$PATH" REAL_GIT="$REAL_GIT" FIXTURE_ROOT="$FIXTURE_ROOT" \
    DISK_AFTER_CLONE="$mode" SOURCE_PLATFORM=gitlab SOURCE_ORG=source SOURCE_TOKEN=unused \
    DEST_PLATFORM=github DEST_ORG=dest DEST_TOKEN=unused DIRECTION=both \
    MIN_FREE_DISK_MB=1024 BUDGET_MINUTES=5 \
    bash "$TEST_ROOT/scripts/git-platform-sync.sh" >"$TEST_ROOT/out.log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected guarded run to fail for post-clone disk result '$mode'" >&2
    cat "$TEST_ROOT/out.log" >&2
    exit 1
  fi
  if grep -q '^push$' "$FIXTURE_ROOT/git-actions.log" 2>/dev/null; then
    echo "FAIL: push occurred after post-clone disk result '$mode'" >&2
    cat "$TEST_ROOT/out.log" >&2
    exit 1
  fi
  local clones
  clones="$(grep -c '^clone$' "$FIXTURE_ROOT/git-actions.log" || true)"
  [[ "$clones" == "1" ]] || { echo "FAIL: expected one clone, got $clones for '$mode'" >&2; exit 1; }
  grep -Fq 'Skipping second sync leg because the disk-space guard stopped the first leg' "$TEST_ROOT/out.log" || {
    echo "FAIL: second leg was not reported skipped for '$mode'" >&2; cat "$TEST_ROOT/out.log" >&2; exit 1;
  }
  grep -Fq "$expected" "$TEST_ROOT/out.log" || {
    echo "FAIL: expected diagnostic '$expected' for '$mode'" >&2; cat "$TEST_ROOT/out.log" >&2; exit 1;
  }
}

run_case low 'Disk-space guard tripped after cloning fixture'
run_case unknown 'Could not determine free disk space after cloning fixture'
printf 'PASS: post-clone disk guard blocks pushes and the second sync leg\n'
