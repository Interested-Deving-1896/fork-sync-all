#!/usr/bin/env bash
#
# ota-deliver.sh
#
# Iterates all opted-in repos in config/ota-registry.yml, assembles a
# per-repo OTA payload via ota-payload-build.sh, and opens a PR against
# each repo with the changes.
#
# Triggered by ota-release.yml on a new semver tag push.
#
# Usage:
#   OTA_VERSION=v1.2.3 GH_TOKEN=ghp_... bash scripts/ota-deliver.sh
#
# Required env:
#   GH_TOKEN      GitHub PAT with repo read + PR write access
#   OTA_VERSION   The semver tag being released (e.g. v1.2.3)
#
# Optional env:
#   REGISTRY_FILE   Path to ota-registry.yml (default: config/ota-registry.yml)
#   BLOCKLIST_FILE  Path to ota-blocklist.yml (default: config/ota-blocklist.yml)
#   MANIFEST_FILE   Path to template-manifest.yml (default: config/template-manifest.yml)
#   DRY_RUN         "true" to skip PR creation
#   REPO_FILTER     Substring filter on repo name (for targeted delivery)
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OTA_VERSION:?OTA_VERSION is required}"

REGISTRY_FILE="${REGISTRY_FILE:-config/ota-registry.yml}"
BLOCKLIST_FILE="${BLOCKLIST_FILE:-config/ota-blocklist.yml}"
MANIFEST_FILE="${MANIFEST_FILE:-config/manifest.yml}"
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
API="https://api.github.com"

delivered=0
skipped=0
failed=0

# ── helpers ───────────────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"; shift 2
  curl -s -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url"
}

log()  { echo "[deliver] $*"; }
warn() { echo "[deliver] WARN: $*" >&2; }

# ── blocklist check ───────────────────────────────────────────────────────────

is_blocklisted() {
  local repo="$1"
  local org="${repo%%/*}"

  # Guard 1: org blocklist
  local blocked_orgs
  mapfile -t blocked_orgs < <(python3 -c "
import sys
in_orgs = False
with open('${BLOCKLIST_FILE}') as f:
    for line in f:
        s = line.strip()
        if s == 'github_orgs:':
            in_orgs = True
        elif s and not s.startswith('- ') and in_orgs:
            in_orgs = False
        elif in_orgs and s.startswith('- '):
            print(s[2:].strip())
" 2>/dev/null || true)

  for blocked_org in "${blocked_orgs[@]}"; do
    if [[ "${org,,}" == "${blocked_org,,}" ]]; then
      return 0
    fi
  done

  return 1
}

is_mirror_chain_profile() {
  local repo="$1"
  # Check if this repo appears in template-consumers.yml with a non-standalone profile
  python3 - "$repo" <<'PYEOF'
import sys, re

repo = sys.argv[1]
repo_name = repo.split('/')[-1]

try:
    with open('config/template-consumers.yml') as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)  # Can't determine — treat as not excluded

# Find the consumer entry for this repo name
# Look for "name: <repo_name>" and the profile on the next few lines
lines = content.splitlines()
in_entry = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == f'name: {repo_name}' or stripped == f"name: '{repo_name}'":
        in_entry = True
        continue
    if in_entry:
        if stripped.startswith('profile:'):
            profile = stripped.split(':', 1)[1].strip()
            # standalone is OTA-eligible; others are not
            if profile != 'standalone':
                sys.exit(0)  # excluded
            else:
                sys.exit(1)  # eligible
        elif stripped.startswith('- name:') or stripped.startswith('name:'):
            break  # next entry — profile not found, default to full (excluded)

sys.exit(0)  # default: excluded (full profile)
PYEOF
}

check_mirror_chain_opt_in() {
  local repo="$1"
  # Returns 0 (opted in) if the repo's .ota/config.yml has mirror_chain_opt_in: true
  local config_content
  config_content=$(gh_api GET "${API}/repos/${repo}/contents/.ota/config.yml" \
    | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
if 'content' in d:
    print(base64.b64decode(d['content']).decode())
" 2>/dev/null || true)

  if echo "$config_content" | grep -q "mirror_chain_opt_in: true"; then
    return 0
  fi
  return 1
}

# ── read registry ─────────────────────────────────────────────────────────────

mapfile -t REGISTRY_REPOS < <(python3 -c "
import sys
in_opted = False
in_entry = False
repo = ''
disabled = False
with open('${REGISTRY_FILE}') as f:
    for line in f:
        s = line.strip()
        if s == 'opted_in:':
            in_opted = True
        elif in_opted and s.startswith('- repo:'):
            if repo and not disabled:
                print(repo)
            repo = s.split(':', 1)[1].strip().strip('\"')
            disabled = False
        elif in_opted and s.startswith('disabled: true'):
            disabled = True
if repo and not disabled:
    print(repo)
" 2>/dev/null || true)

log "Registry contains ${#REGISTRY_REPOS[@]} opted-in repos"
log "OTA version: ${OTA_VERSION}"
[[ "$DRY_RUN" == "true" ]] && log "Dry run — no PRs will be opened"
echo ""

# ── deliver to each repo ──────────────────────────────────────────────────────

for repo in "${REGISTRY_REPOS[@]}"; do
  [[ -z "$repo" ]] && continue

  repo_name="${repo##*/}"
  if [[ -n "$REPO_FILTER" && "$repo_name" != *"$REPO_FILTER"* ]]; then
    (( skipped++ ))
    continue
  fi

  log "Processing ${repo}..."

  # Guard 1: org blocklist
  if is_blocklisted "$repo"; then
    if check_mirror_chain_opt_in "$repo"; then
      log "  Mirror-chain repo with explicit opt-in — proceeding"
    else
      log "  Skipped — org is in blocklist (mirror chain)"
      (( skipped++ ))
      continue
    fi
  fi

  # Guard 2: profile filter
  if is_mirror_chain_profile "$repo"; then
    if check_mirror_chain_opt_in "$repo"; then
      log "  Non-standalone profile with explicit opt-in — proceeding"
    else
      log "  Skipped — non-standalone profile (use mirror_chain_opt_in: true to override)"
      (( skipped++ ))
      continue
    fi
  fi

  # Assemble payload
  PAYLOAD_DIR=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${PAYLOAD_DIR}'" RETURN

  rc=0
  TARGET_REPO="$repo" \
  PAYLOAD_DIR="$PAYLOAD_DIR" \
  MANIFEST_FILE="$MANIFEST_FILE" \
  GH_TOKEN="$GH_TOKEN" \
  DRY_RUN="$DRY_RUN" \
  bash scripts/ota-payload-build.sh --full || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    warn "Payload build failed for ${repo} (exit ${rc})"
    (( failed++ ))
    continue
  fi

  # Check if there are any changes
  if [[ ! -f "${PAYLOAD_DIR}/.ota-changed-files" ]] || \
     [[ ! -s "${PAYLOAD_DIR}/.ota-changed-files" ]]; then
    log "  No changes for ${repo} — already up to date"
    (( skipped++ ))
    continue
  fi

  changed_count=$(wc -l < "${PAYLOAD_DIR}/.ota-changed-files")
  log "  ${changed_count} files to update"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY: would open PR against ${repo} for ${OTA_VERSION}"
    (( delivered++ ))
    continue
  fi

  # Get default branch
  default_branch=$(gh_api GET "${API}/repos/${repo}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" \
    2>/dev/null || echo "main")

  # Clone target, apply payload, push branch, open PR
  CLONE_DIR=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${CLONE_DIR}'" RETURN

  clone_url="https://x-access-token:${GH_TOKEN}@github.com/${repo}.git"
  if ! git clone --quiet --depth=1 "$clone_url" "${CLONE_DIR}/repo" 2>/dev/null; then
    warn "Failed to clone ${repo}"
    (( failed++ ))
    continue
  fi

  pushd "${CLONE_DIR}/repo" >/dev/null

  ota_branch="ota/${OTA_VERSION}"
  git checkout -b "$ota_branch" 2>/dev/null

  # Apply payload files
  while IFS= read -r changed_file; do
    [[ "$changed_file" == ".ota-changed-files" ]] && continue
    dest_dir="$(dirname "$changed_file")"
    mkdir -p "$dest_dir"
    cp "${PAYLOAD_DIR}/${changed_file}" "$changed_file"
    git add "$changed_file"
  done < "${PAYLOAD_DIR}/.ota-changed-files"

  if git diff --cached --quiet; then
    log "  No staged changes after applying payload — skipping"
    popd >/dev/null
    (( skipped++ ))
    continue
  fi

  git -c user.name="ota-bot" -c user.email="ota@fork-sync-all" \
    commit -m "chore: OTA update ${OTA_VERSION}

Automated update from fork-sync-all ${OTA_VERSION}.
Source: https://github.com/Interested-Deving-1896/fork-sync-all/releases/tag/${OTA_VERSION}

Co-authored-by: Ona <no-reply@ona.com>" 2>/dev/null

  if ! git push --quiet origin "$ota_branch" 2>/dev/null; then
    warn "Failed to push ${ota_branch} to ${repo}"
    popd >/dev/null
    (( failed++ ))
    continue
  fi

  popd >/dev/null

  # Open PR
  pr_body="## OTA Update ${OTA_VERSION}

This PR was opened automatically by the [fork-sync-all OTA system](https://github.com/Interested-Deving-1896/fork-sync-all).

**Changed files (${changed_count}):**
\`\`\`
$(cat "${PAYLOAD_DIR}/.ota-changed-files" | grep -v '^\.ota-changed-files$')
\`\`\`

**Release notes:** https://github.com/Interested-Deving-1896/fork-sync-all/releases/tag/${OTA_VERSION}

To opt out of future OTA updates, set \`enabled: false\` in \`.ota/config.yml\`."

  pr_result=$(gh_api POST "${API}/repos/${repo}/pulls" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
  'title': 'chore: OTA update ${OTA_VERSION}',
  'head': '${ota_branch}',
  'base': '${default_branch}',
  'body': sys.stdin.read()
}))
" <<< "$pr_body")")

  pr_url=$(echo "$pr_result" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || true)

  if [[ -n "$pr_url" ]]; then
    log "  PR opened: ${pr_url}"
    (( delivered++ ))
  else
    warn "PR creation failed for ${repo}: $(echo "$pr_result" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null || true)"
    (( failed++ ))
  fi
done

echo ""
echo "========================================"
echo "  OTA delivery complete — ${OTA_VERSION}"
echo "  Delivered:  ${delivered}"
echo "  Skipped:    ${skipped}"
echo "  Failed:     ${failed}"
echo "========================================"

[[ "$failed" -gt 0 ]] && exit 1
exit 0
