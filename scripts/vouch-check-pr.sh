#!/usr/bin/env bash
#
# vouch-check-pr.sh
#
# Hybrid A/B/C PR trust gate for fork-sync-all and template consumers.
#
# Reads the VOUCHED.td file and the PR's changed file paths, then selects
# the appropriate response at runtime:
#
#   Path C — author is DENOUNCED
#             Always auto-close, post denouncement comment, exit 1.
#
#   Path B — author is UNKNOWN + PR touches sensitive paths
#             Sensitive: .github/workflows/, scripts/, config/,
#                        registered-imports.json, .github/VOUCHED*.td
#             Fail the check (exit 1), post vouch-required comment.
#             PR stays open for maintainer review.
#
#   Path A — author is UNKNOWN + PR touches only non-sensitive paths
#             Post warn-only label + comment, exit 0 (check passes).
#             Maintainer can merge at their discretion.
#
#   PASS  — author is VOUCHED or is a bot/collaborator
#             Exit 0, no comment.
#
# Required env:
#   GH_TOKEN      GitHub PAT with repo + pull-requests write
#   PR_NUMBER     PR number
#   PR_AUTHOR     GitHub login of the PR author
#   REPO          owner/repo
#
# Optional env:
#   VOUCHED_FILE          Path to VOUCHED.td (default: .github/VOUCHED.td)
#   DRY_RUN               true = report only, no API writes
#   SENSITIVE_PATHS       Space-separated list of sensitive path prefixes
#                         (overrides built-in defaults)
#   REQUIRE_VOUCH_ON_SENSITIVE  true (default) | false
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_AUTHOR:?PR_AUTHOR required}"
: "${REPO:?REPO required}"

VOUCHED_FILE="${VOUCHED_FILE:-.github/VOUCHED.td}"
DRY_RUN="${DRY_RUN:-false}"
REQUIRE_VOUCH_ON_SENSITIVE="${REQUIRE_VOUCH_ON_SENSITIVE:-true}"
API="${API:-https://api.github.com}"

# Default sensitive path prefixes
DEFAULT_SENSITIVE=(
  ".github/workflows/"
  "scripts/"
  "config/"
  "registered-imports.json"
  ".github/VOUCHED"
)

info() { echo "[vouch-check-pr] $*" >&2; }
warn() { echo "[vouch-check-pr] WARN: $*" >&2; }

gh_get() {
  curl -sf -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$1" 2>/dev/null || echo "{}"
}

gh_post() {
  local url="$1" data="$2"
  [[ "$DRY_RUN" == "true" ]] && { info "[dry] POST $url"; return 0; }
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" "$url" >/dev/null 2>&1
}

gh_patch() {
  local url="$1" data="$2"
  [[ "$DRY_RUN" == "true" ]] && { info "[dry] PATCH $url"; return 0; }
  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" "$url" >/dev/null 2>&1
}

# ── Read VOUCHED.td ───────────────────────────────────────────────────────────

check_vouch_status() {
  local author="$1"
  local vouched_file="$2"

  if [[ ! -f "$vouched_file" ]]; then
    echo "unknown"
    return
  fi

  local lower_author
  lower_author=$(echo "$author" | tr '[:upper:]' '[:lower:]')

  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Determine if denounced (leading -)
    local raw="$line"
    local denounced=false
    if [[ "$raw" == -* ]]; then
      denounced=true
      raw="${raw#-}"
    fi

    # Strip platform prefix (github:username → username)
    local entry
    if [[ "$raw" == *:* ]]; then
      entry="${raw#*:}"   # everything after first colon
    else
      entry="$raw"
    fi
    entry="${entry%% *}"  # strip trailing reason/comment

    local lower_entry
    lower_entry=$(echo "$entry" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower_entry" == "$lower_author" ]]; then
      [[ "$denounced" == "true" ]] && echo "denounced" || echo "vouched"
      return
    fi
  done < "$vouched_file"

  echo "unknown"
}

# ── Check if author is a bot or collaborator ──────────────────────────────────

is_bot_or_collaborator() {
  local author="$1"

  # Bots
  if [[ "$author" == *"[bot]"* || "$author" == "dependabot" || \
        "$author" == "github-actions" || "$author" == "renovate" ]]; then
    echo "true"; return
  fi

  # Collaborator with write+ access
  local perm
  perm=$(gh_get "${API}/repos/${REPO}/collaborators/${author}/permission" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('permission','none'))" 2>/dev/null || echo "none")

  case "$perm" in
    admin|maintain|write) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ── Get changed file paths for the PR ────────────────────────────────────────

get_pr_files() {
  local page=1
  while true; do
    local result
    result=$(gh_get "${API}/repos/${REPO}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}")
    local count
    count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | python3 -c "
import sys, json
files = json.load(sys.stdin)
for f in files:
    print(f.get('filename',''))
" 2>/dev/null
    [[ "$count" -lt 100 ]] && break
    (( page++ ))
  done
}

# ── Check if any changed file is sensitive ────────────────────────────────────

touches_sensitive_paths() {
  local files="$1"

  # Use custom list if provided, else defaults
  local sensitive_prefixes=()
  if [[ -n "${SENSITIVE_PATHS:-}" ]]; then
    read -ra sensitive_prefixes <<< "$SENSITIVE_PATHS"
  else
    sensitive_prefixes=("${DEFAULT_SENSITIVE[@]}")
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    for prefix in "${sensitive_prefixes[@]}"; do
      if [[ "$file" == "$prefix"* || "$file" == "$prefix" ]]; then
        echo "true"
        return
      fi
    done
  done <<< "$files"

  echo "false"
}

# ── Post comment ──────────────────────────────────────────────────────────────

post_comment() {
  local body="$1"
  gh_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/comments" \
    "$(python3 -c "import json,sys; print(json.dumps({'body': sys.stdin.read()}))" <<< "$body")"
}

add_label() {
  local label="$1"
  gh_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
    "$(python3 -c "import json; print(json.dumps({'labels': ['$label']}))")"
}

close_pr() {
  gh_patch "${API}/repos/${REPO}/pulls/${PR_NUMBER}" \
    '{"state":"closed"}'
}

# ── Main ──────────────────────────────────────────────────────────────────────

info "Checking PR #${PR_NUMBER} author: ${PR_AUTHOR}"

# Skip bots and collaborators
if [[ "$(is_bot_or_collaborator "$PR_AUTHOR")" == "true" ]]; then
  info "Author is bot or collaborator — skipping vouch check"
  echo "status=skipped" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# Read vouch status
status=$(check_vouch_status "$PR_AUTHOR" "$VOUCHED_FILE")
info "Vouch status: ${status}"

case "$status" in
  vouched)
    info "Author is vouched — passing"
    echo "status=vouched" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
    ;;

  denounced)
    # Path C — always close
    info "Author is DENOUNCED — closing PR"
    post_comment "$(cat <<COMMENT
👋 @${PR_AUTHOR} — this account has been denounced and cannot contribute to this repository.

If you believe this is an error, please contact the maintainers directly.
COMMENT
)"
    close_pr
    echo "status=denounced" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
    ;;

  unknown)
    # Get changed files
    pr_files=$(get_pr_files)
    sensitive=$(touches_sensitive_paths "$pr_files")
    info "Touches sensitive paths: ${sensitive}"

    if [[ "$sensitive" == "true" && "$REQUIRE_VOUCH_ON_SENSITIVE" == "true" ]]; then
      # Path B — block merge
      info "Unknown author + sensitive paths — blocking PR"
      post_comment "$(cat <<COMMENT
👋 @${PR_AUTHOR} — thanks for the contribution!

This PR touches sensitive paths (\`.github/workflows/\`, \`scripts/\`, \`config/\`, or \`registered-imports.json\`) and requires a maintainer vouch before it can be merged.

**What this means:** A maintainer needs to review your contribution and comment \`vouch @${PR_AUTHOR}\` on this PR to approve it.

**Why we do this:** These paths control the automation infrastructure for this org. We require explicit trust for changes here.

This check will re-run automatically once you are vouched.
COMMENT
)"
      add_label "needs-vouch"
      echo "status=blocked" >> "${GITHUB_OUTPUT:-/dev/null}"
      exit 1
    else
      # Path A — warn only
      info "Unknown author + non-sensitive paths — warning only"
      post_comment "$(cat <<COMMENT
👋 @${PR_AUTHOR} — thanks for the contribution!

You are not yet a vouched contributor. A maintainer will review this PR.

To become a vouched contributor for future PRs, ask a maintainer to comment \`vouch @${PR_AUTHOR}\` on any issue or PR.
COMMENT
)"
      add_label "needs-vouch"
      echo "status=warned" >> "${GITHUB_OUTPUT:-/dev/null}"
      exit 0
    fi
    ;;
esac
