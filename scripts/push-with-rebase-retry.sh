#!/usr/bin/env bash
# Push the current HEAD while safely absorbing concurrent updates to the target
# branch.  A real rebase conflict or a non-concurrency push error remains fatal.

set -euo pipefail

remote="${PUSH_REMOTE:-origin}"
branch="${PUSH_BRANCH:-main}"
max_attempts="${PUSH_REBASE_ATTEMPTS:-4}"

log() { echo "[push-with-rebase-retry] $*" >&2; }

if ! [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
  log "PUSH_REBASE_ATTEMPTS must be a positive integer (got: ${max_attempts})."
  exit 1
fi

fetch_target() {
  if ! git fetch --no-tags "$remote" "$branch"; then
    log "Failed to fetch ${remote}/${branch}; refusing to push stale history."
    return 1
  fi
}

rebase_onto_fetched_target() {
  if git merge-base --is-ancestor HEAD FETCH_HEAD; then
    log "Current commit is already present on ${remote}/${branch}."
    return 2
  fi

  if ! git rebase FETCH_HEAD; then
    git rebase --abort >/dev/null 2>&1 || true
    log "Rebase onto the latest ${remote}/${branch} conflicted; no push was attempted."
    return 1
  fi
}

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  fetch_target

  rebase_rc=0
  rebase_onto_fetched_target || rebase_rc=$?
  if (( rebase_rc == 2 )); then
    exit 0
  elif (( rebase_rc != 0 )); then
    exit "$rebase_rc"
  fi

  if git push "$remote" "HEAD:${branch}"; then
    log "Pushed ${branch} successfully on attempt ${attempt}."
    exit 0
  else
    push_rc=$?
  fi

  # Classify the rejection from repository state rather than error text.  If
  # the remote did not move past/diverge from our rebased HEAD, retrying would
  # hide an authentication, policy, or transport failure.
  fetch_target
  if git merge-base --is-ancestor HEAD FETCH_HEAD; then
    log "Current commit appeared on ${remote}/${branch} after the push response."
    exit 0
  fi
  if git merge-base --is-ancestor FETCH_HEAD HEAD; then
    log "Push failed even though ${remote}/${branch} did not advance; not retrying a non-concurrency error."
    exit "$push_rc"
  fi

  if (( attempt == max_attempts )); then
    log "${remote}/${branch} advanced during all ${max_attempts} push attempts; giving up safely."
    exit "$push_rc"
  fi
  log "${remote}/${branch} advanced during push attempt ${attempt}; rebasing and retrying."
done

