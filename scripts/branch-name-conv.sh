#!/usr/bin/env bash
#
# Platform-agnostic branch name encoder/decoder.
#
# Different git platforms impose different restrictions on branch names.
# This script provides two functions — branch_encode and branch_decode —
# that convert branch names to a form safe on all known platforms, and back.
#
# Encoding scheme
# ───────────────
# The only characters that cause cross-platform problems in practice are
# forward slashes at depths that trigger platform-specific pre-receive hooks
# (e.g. GitLab rejects names ending in YYYY-MM-DD at depth ≥ 2, and some
# Bitbucket/Azure configurations reject deep slash hierarchies).
#
# Rather than trying to enumerate every platform rule, we encode names that
# would be problematic by replacing each "/" with the escape token "--S--".
# Names that are already safe (depth ≤ 1, or no date terminal segment) are
# passed through unchanged, keeping the common case (feat/*, docs/*, deps/*)
# human-readable on all platforms.
#
# Escape token: "--S--"  (double-hyphen, S for Slash, double-hyphen)
#   - Valid on GitHub, GitLab, Bitbucket, Gitea, Azure DevOps, Sourcehut
#   - Not a natural occurrence in branch names (hyphens are common; "--S--"
#     as a unit is not)
#   - Reversible: decode replaces "--S--" back to "/"
#
# Examples
# ────────
#   upstream-commits/OpenOS-Project-OOC/eggs-ai/2026-05-08
#     → upstream-commits--S--OpenOS-Project-OOC--S--eggs-ai--S--2026-05-08
#
#   dependabot/github_actions/actions/checkout-6
#     → dependabot--S--github_actions--S--actions--S--checkout-6
#
#   feat/add-bootloaders          → feat/add-bootloaders   (unchanged, depth=1)
#   openos/ci                     → openos/ci              (unchanged, depth=1)
#   main                          → main                   (unchanged, depth=0)
#
# Platform validity matrix (encoded form)
# ───────────────────────────────────────
#   GitHub        ✓  no restrictions on hyphens
#   GitLab        ✓  no pre-receive hook triggers
#   Bitbucket     ✓  hyphens allowed, no depth limit
#   Gitea         ✓  follows standard git-check-ref-format
#   Azure DevOps  ✓  hyphens allowed
#   Sourcehut     ✓  follows standard git-check-ref-format
#
# Usage
# ─────
#   source scripts/branch-name-conv.sh
#   encoded=$(branch_encode "upstream-commits/Org/repo/2026-05-08")
#   original=$(branch_decode "$encoded")
#
# Or as a standalone filter (one branch name per line on stdin):
#   git for-each-ref --format='%(refname:short)' refs/heads/ \
#     | branch_encode_stdin
#
# Environment
# ───────────
#   BRANCH_CONV_DEPTH_THRESHOLD  — minimum slash depth to trigger encoding
#                                  (default: 2, i.e. depth > 1)
#   BRANCH_CONV_ALWAYS_ENCODE    — set to "1" to encode all names regardless
#                                  of depth (useful for strict platforms)

BRANCH_CONV_TOKEN="${BRANCH_CONV_TOKEN:---S--}"
BRANCH_CONV_DEPTH_THRESHOLD="${BRANCH_CONV_DEPTH_THRESHOLD:-2}"
BRANCH_CONV_ALWAYS_ENCODE="${BRANCH_CONV_ALWAYS_ENCODE:-0}"

# ── helpers ───────────────────────────────────────────────────────────────────

_branch_depth() {
  # Count the number of "/" in a branch name
  local name="$1"
  echo "${name//[^\/]}" | wc -c | tr -d ' '
  # wc -c counts the newline too, so result = slash_count + 1
  # Subtract 1 to get actual depth
}

_branch_needs_encoding() {
  local name="$1"
  [[ "$BRANCH_CONV_ALWAYS_ENCODE" == "1" ]] && return 0

  local raw_depth
  raw_depth=$(echo -n "${name//[^\/]}" | wc -c)

  # Encode if depth >= threshold
  (( raw_depth >= BRANCH_CONV_DEPTH_THRESHOLD )) && return 0

  return 1
}

# ── public API ────────────────────────────────────────────────────────────────

# branch_encode NAME
# Encodes a branch name for safe use on all platforms.
# Prints the encoded name (or the original if no encoding needed).
branch_encode() {
  local name="$1"
  if _branch_needs_encoding "$name"; then
    printf '%s' "${name//\//${BRANCH_CONV_TOKEN}}"
  else
    printf '%s' "$name"
  fi
}

# branch_decode NAME
# Decodes a branch name previously encoded by branch_encode.
# Prints the original name.
branch_decode() {
  local name="$1"
  printf '%s' "${name//${BRANCH_CONV_TOKEN}/\/}"
}

# branch_encode_stdin
# Reads branch names one per line from stdin, encodes each, prints to stdout.
branch_encode_stdin() {
  while IFS= read -r name; do
    branch_encode "$name"
    printf '\n'
  done
}

# branch_decode_stdin
# Reads branch names one per line from stdin, decodes each, prints to stdout.
branch_decode_stdin() {
  while IFS= read -r name; do
    branch_decode "$name"
    printf '\n'
  done
}

# push_branches_encoded REMOTE [EXTRA_GIT_ARGS...]
# Pushes all local branches to REMOTE, encoding names that would be invalid
# on stricter platforms. Branches that don't need encoding are pushed with
# their original names. Returns non-zero if any push fails.
#
# Must be called from inside a git working directory (bare clone).
push_branches_encoded() {
  local remote="$1"; shift
  local extra_args=("$@")
  local refspecs=()
  local skipped=0

  while IFS= read -r fullref; do
    [[ -z "$fullref" ]] && continue
    # Strip refs/heads/ prefix to get the bare branch name.
    local branch="${fullref#refs/heads/}"
    # Skip any ref whose bare name is HEAD — these are either symbolic refs
    # or real commits stored at refs/heads/HEAD, both of which produce broken
    # refspecs when pushed (git resolves HEAD specially).
    [[ "$branch" == "HEAD" ]] && continue
    local encoded
    encoded=$(branch_encode "$branch")
    refspecs+=("+refs/heads/${branch}:refs/heads/${encoded}")
  done < <(git for-each-ref --format='%(refname)' refs/heads/)

  if [[ ${#refspecs[@]} -eq 0 ]]; then
    return 0
  fi

  git push "$remote" "${extra_args[@]}" "${refspecs[@]}"
}

# push_branches_decoded REMOTE [EXTRA_GIT_ARGS...]
# Pushes all local branches to REMOTE, decoding any encoded names back to
# their original form. Used when pushing from GitLab back to GitHub.
#
# Must be called from inside a git working directory (bare clone).
push_branches_decoded() {
  local remote="$1"; shift
  local extra_args=("$@")
  local refspecs=()

  while IFS= read -r fullref; do
    [[ -z "$fullref" ]] && continue
    local branch="${fullref#refs/heads/}"
    # Skip HEAD refs (see push_branches_encoded for explanation).
    [[ "$branch" == "HEAD" ]] && continue
    local decoded
    decoded=$(branch_decode "$branch")
    # Skip upstream-commits/* branches — these originate on GitHub and must
    # not be round-tripped through GitLab. Multiple encoded variants can
    # decode to the same ref, causing "dst ref receives from more than one src".
    [[ "$decoded" == upstream-commits/* ]] && continue
    refspecs+=("+refs/heads/${branch}:refs/heads/${decoded}")
  done < <(git for-each-ref --format='%(refname)' refs/heads/)

  if [[ ${#refspecs[@]} -eq 0 ]]; then
    return 0
  fi

  git push "$remote" "${extra_args[@]}" "${refspecs[@]}"
}
