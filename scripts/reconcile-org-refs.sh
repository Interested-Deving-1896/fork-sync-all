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

SCAN_SUFFIXES=(
  "pyproject.toml" ".yml" ".yaml" ".sh" "Makefile" "go.mod"
  "CMakeLists.txt" "PKGBUILD" ".spec" "setup.py" "setup.cfg"
  "Cargo.toml" "debian/control" "debian/changelog" "debian/rules"
  ".service" ".timer" ".json" ".md" ".toml" ".txt"
)

SKIP_DIRS=("vendor/" "node_modules/" ".git/")
EXCLUDED_REPOS=("fork-sync-all" "org-mirror")

# Write the patcher to a temp file — avoids heredoc/stdin conflicts
PATCHER=$(mktemp /tmp/patch_refs_XXXXXX.py)
cat > "$PATCHER" << 'PYEOF'
#!/usr/bin/env python3
# Usage: python3 patcher.py <file> <src> <dst>
# Rewrites src->dst in file, skipping `if: github.repository ==` lines.
import sys, re

path, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
guard_re = re.compile(r'if:\s+github\.repository\s*==')

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except OSError as e:
    print(f"skip", file=sys.stderr)
    sys.exit(0)

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
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print("MODIFIED")
else:
    print("UNCHANGED")
PYEOF
trap 'rm -f "$PATCHER"' EXIT

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
  for ex in "${EXCLUDED_REPOS[@]}"; do [[ "$repo" == "$ex" ]] && return 0; done
  return 1
}

in_skip_dir() {
  local p="$1"
  for d in "${SKIP_DIRS[@]}"; do [[ "$p" == "$d"* ]] && return 0; done
  return 1
}

should_scan() {
  local p="$1" base
  base=$(basename "$p")
  for suf in "${SCAN_SUFFIXES[@]}"; do
    [[ "$base" == "$suf" || "$base" == *"$suf" || "$p" == *"$suf" ]] && return 0
  done
  return 1
}

get_org_repos() {
  local org="$1" page=1
  while true; do
    local result count
    result=$(api_get "${API}/orgs/${org}/repos?type=all&per_page=100&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
}

process_repo() {
  local org="$1" repo="$2" target_org="$3" default_branch="$4"
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  echo "  Processing ${org}/${repo} (-> ${target_org})..."

  local tree files
  tree=$(api_get "${API}/repos/${org}/${repo}/git/trees/${default_branch}?recursive=1")
  files=$(echo "$tree" | jq -r '.tree[]? | select(.type=="blob") | .path' 2>/dev/null)
  [[ -z "$files" ]] && { echo "    no files (empty repo or API error)"; return; }

  local patched=0

  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    in_skip_dir "$filepath" && continue
    should_scan "$filepath" || continue

    local file_data sha content_b64
    file_data=$(api_get "${API}/repos/${org}/${repo}/contents/${filepath}?ref=${default_branch}")
    sha=$(echo "$file_data" | jq -r '.sha // empty')
    content_b64=$(echo "$file_data" | jq -r '.content // empty')
    [[ -z "$sha" || -z "$content_b64" ]] && continue

    local tmpfile="${tmpdir}/workfile"
    echo "$content_b64" | base64 -d > "$tmpfile" 2>/dev/null || continue

    grep -q "$UPSTREAM_OWNER" "$tmpfile" 2>/dev/null || continue

    local status
    status=$(python3 "$PATCHER" "$tmpfile" "$UPSTREAM_OWNER" "$target_org")
    [[ "$status" != "MODIFIED" ]] && continue

    local new_b64 payload http_code
    new_b64=$(base64 -w 0 "$tmpfile")
    payload=$(jq -n \
      --arg msg "ci: rebase org refs ${UPSTREAM_OWNER} -> ${target_org} [auto]" \
      --arg content "$new_b64" \
      --arg sha "$sha" \
      --arg branch "$default_branch" \
      '{message: $msg, content: $content, sha: $sha, branch: $branch}')

    http_code=$(api_put \
      "${API}/repos/${org}/${repo}/contents/${filepath}" -d "$payload")

    if [[ "$http_code" == "200" ]]; then
      echo "    patched: $filepath"
      (( patched++ )) || true
    else
      echo "    FAILED:  $filepath (HTTP $http_code)"
    fi

  done <<< "$files"

  echo "    done: $patched file(s) updated"
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
login=$(api_get "${API}/user" | jq -r '.login // empty')
[[ -z "$login" ]] && { echo "ERROR: GH_TOKEN invalid."; exit 1; }
echo "Authenticated as: $login"
echo ""

total_repos=0
total_skipped=0

for org in "$OSP_ORG" "$OOC_ORG"; do
  echo "========================================"
  echo "Scanning ${org}"
  echo "========================================"

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if is_excluded "$repo"; then (( total_skipped++ )) || true; continue; fi

    upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}")
    upstream_name=$(echo "$upstream_info" | jq -r '.name // empty')
    [[ -z "$upstream_name" ]] && { (( total_skipped++ )) || true; continue; }

    default_branch=$(echo "$upstream_info" | jq -r '.default_branch // "main"')
    process_repo "$org" "$repo" "$org" "$default_branch"
    (( total_repos++ )) || true
    echo ""

  done < <(get_org_repos "$org")
done

echo "========================================"
echo "  Reconciliation complete"
echo "  Repos processed: $total_repos"
echo "  Repos skipped:   $total_skipped"
echo "========================================"
exit 0
