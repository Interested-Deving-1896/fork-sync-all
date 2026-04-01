#!/usr/bin/env bash
#
# For every repo in OSP and OOC that has a counterpart in UPSTREAM_OWNER,
# scan all text files for UPSTREAM_OWNER references and rewrite them to
# point to the correct mirror org — skipping `if: github.repository ==`
# guard lines so mirrors stay passive.
#
# Runs via the GitHub API: no full clone required. Each changed file is
# fetched, patched in memory, and PUT back as a single commit.
#
# Requires: GH_TOKEN (repo + workflow scopes), UPSTREAM_OWNER, OSP_ORG, OOC_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

# Files/paths to scan (suffix or exact basename match)
SCAN_SUFFIXES=(
  "pyproject.toml"
  ".yml"
  ".yaml"
  ".sh"
  "Makefile"
  "go.mod"
  "CMakeLists.txt"
  "PKGBUILD"
  ".spec"
  "setup.py"
  "setup.cfg"
  "Cargo.toml"
  "debian/control"
  "debian/changelog"
  "debian/rules"
  ".service"
  ".timer"
  ".json"
  ".md"
  ".toml"
  ".txt"
)

# Directories to never touch
SKIP_DIRS=("vendor/" "node_modules/" ".git/")

# Repos excluded from processing
EXCLUDED_REPOS=("fork-sync-all" "org-mirror")

# ── helpers ──────────────────────────────────────────────────────────────────

api_get() {
  curl --disable --silent \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "$@"
}

api_put() {
  local url="$1"; shift
  curl --disable --silent -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

is_excluded() {
  local repo="$1"
  for ex in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$ex" ]] && return 0
  done
  return 1
}

in_skip_dir() {
  local p="$1"
  for d in "${SKIP_DIRS[@]}"; do
    [[ "$p" == "$d"* ]] && return 0
  done
  return 1
}

should_scan() {
  local p="$1"
  local base
  base=$(basename "$p")
  for suf in "${SCAN_SUFFIXES[@]}"; do
    # Exact basename match (e.g. "Makefile") or suffix match
    if [[ "$base" == "$suf" ]] || [[ "$base" == *"$suf" ]] || [[ "$p" == *"$suf" ]]; then
      return 0
    fi
  done
  return 1
}

# Patch content: replace UPSTREAM_OWNER with TARGET_ORG, skip guard lines
patch_content() {
  local content="$1"
  local src="$2"
  local dst="$3"
  python3 - "$src" "$dst" << PYEOF
import sys, re, base64

src, dst = sys.argv[1], sys.argv[2]
guard_re = re.compile(r'if:\s+github\.repository\s*==')

import sys
content = sys.stdin.read()
lines = content.splitlines(keepends=True)
out = []
modified = False
for line in lines:
    if guard_re.search(line):
        out.append(line)
    else:
        new = line.replace(src, dst)
        if new != line:
            modified = True
        out.append(new)

if modified:
    print("MODIFIED")
    sys.stdout.write("".join(out))
else:
    print("UNCHANGED")
PYEOF
}

# Process a single repo: scan files, patch, commit changed ones
process_repo() {
  local org="$1"
  local repo="$2"
  local target_org="$3"
  local default_branch="$4"

  echo "  Processing ${org}/${repo} (→ ${target_org})..."

  # Get recursive file tree
  local tree
  tree=$(api_get "${API}/repos/${org}/${repo}/git/trees/${default_branch}?recursive=1")
  local files
  files=$(echo "$tree" | jq -r '.tree[]? | select(.type=="blob") | .path' 2>/dev/null)

  if [[ -z "$files" ]]; then
    echo "    no files found (empty repo or API error)"
    return
  fi

  local patched=0

  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    in_skip_dir "$filepath" && continue
    should_scan "$filepath" || continue

    # Fetch file
    local file_data
    file_data=$(api_get "${API}/repos/${org}/${repo}/contents/${filepath}?ref=${default_branch}")
    local sha content_b64
    sha=$(echo "$file_data" | jq -r '.sha // empty')
    content_b64=$(echo "$file_data" | jq -r '.content // empty')

    [[ -z "$sha" || -z "$content_b64" ]] && continue

    # Decode
    local content
    content=$(echo "$content_b64" | base64 -d 2>/dev/null) || continue

    # Skip if no reference to upstream owner
    echo "$content" | grep -q "$UPSTREAM_OWNER" || continue

    # Patch
    local patch_result
    patch_result=$(echo "$content" | patch_content "$content" "$UPSTREAM_OWNER" "$target_org")
    local status
    status=$(echo "$patch_result" | head -1)

    [[ "$status" != "MODIFIED" ]] && continue

    local new_content
    new_content=$(echo "$patch_result" | tail -n +2)

    # Encode and commit
    local new_b64
    new_b64=$(echo "$new_content" | base64 -w 0)

    local payload
    payload=$(jq -n \
      --arg msg "ci: rebase org refs ${UPSTREAM_OWNER} → ${target_org} [auto]" \
      --arg content "$new_b64" \
      --arg sha "$sha" \
      --arg branch "$default_branch" \
      '{message: $msg, content: $content, sha: $sha, branch: $branch}')

    local http_code
    http_code=$(api_put \
      "${API}/repos/${org}/${repo}/contents/${filepath}" -d "$payload")

    if [[ "$http_code" == "200" ]]; then
      echo "    patched: $filepath (HTTP $http_code)"
      (( patched++ )) || true
    else
      echo "    FAILED:  $filepath (HTTP $http_code)"
    fi

  done <<< "$files"

  echo "    done: $patched file(s) updated"
}

# Get all repos for an org
get_org_repos() {
  local org="$1"
  local page=1
  while true; do
    local result count
    result=$(api_get "${API}/orgs/${org}/repos?type=all&per_page=100&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
login=$(api_get "${API}/user" | jq -r '.login // empty')
[[ -z "$login" ]] && { echo "ERROR: GH_TOKEN invalid."; exit 1; }
echo "Authenticated as: $login"
echo ""

total_repos=0
total_skipped=0

for org_pair in "${OSP_ORG}:${OSP_ORG}" "${OOC_ORG}:${OOC_ORG}"; do
  org="${org_pair%%:*}"
  target_org="${org_pair##*:}"

  echo "════════════════════════════════════════"
  echo "Scanning ${org} (rewriting → ${target_org})"
  echo "════════════════════════════════════════"

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue

    if is_excluded "$repo"; then
      (( total_skipped++ )) || true
      continue
    fi

    # Only process repos that exist on upstream
    upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}")
    upstream_name=$(echo "$upstream_info" | jq -r '.name // empty')
    [[ -z "$upstream_name" ]] && { (( total_skipped++ )) || true; continue; }

    default_branch=$(echo "$upstream_info" | jq -r '.default_branch // "main"')

    process_repo "$org" "$repo" "$target_org" "$default_branch"
    (( total_repos++ )) || true
    echo ""

  done < <(get_org_repos "$org")
done

echo "════════════════════════════════════════"
echo "  Reconciliation complete"
echo "  Repos processed: $total_repos"
echo "  Repos skipped:   $total_skipped"
echo "════════════════════════════════════════"
exit 0
