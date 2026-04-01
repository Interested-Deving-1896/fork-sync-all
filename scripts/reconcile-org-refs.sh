#!/usr/bin/env bash
#
# Rewrite org references across all mirror repos using GitHub code search
# to find only files that actually need patching — avoiding full tree scans.
#
# Substitution rules:
#   Interested-Deving-1896 repos: pieroproietti -> Interested-Deving-1896
#   OSP repos:  Interested-Deving-1896 -> OSP,  pieroproietti -> OSP
#   OOC repos:  Interested-Deving-1896 -> OOC,  OpenOS-Project-OSP -> OOC,
#               pieroproietti -> OOC
#
# Lines never rewritten:
#   - `if: github.repository ==`  (workflow job guards — mirrors stay passive)
#   - lines containing polkit/D-Bus action IDs (com.github.pieroproietti.*)
#   - lines containing penguins-bootloaders (upstream asset source URLs)
#
# Files never touched:
#   - sync-pieroproietti-forks.* and rebase-lts.* (intentionally reference upstream)
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, OSP_ORG, OOC_ORG
#
set -uo pipefail

: "${GH_TOKEN:?required}"
: "${UPSTREAM_OWNER:?required}"
: "${OSP_ORG:?required}"
: "${OOC_ORG:?required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

api_get() { curl --disable --silent "${AUTH[@]}" "$@"; }

# Write patcher to temp file once
PATCHER=$(mktemp /tmp/patch_refs_XXXXXX.py)
cat > "$PATCHER" << 'PYEOF'
#!/usr/bin/env python3
# Usage: python3 patcher.py <file> <src1> <dst1> [<src2> <dst2> ...]
import sys, re, os

args = sys.argv[1:]
path = args[0]
pairs = [(args[i], args[i+1]) for i in range(1, len(args)-1, 2)]

guard_re = re.compile(r'if:\s+github\.repository\s*==')
preserve_re = re.compile(
    r'com\.github\.pieroproietti\.|'   # polkit/D-Bus action IDs
    r'penguins-bootloaders'             # upstream asset source URLs
)
PRESERVE_FILES = {
    "sync-pieroproietti-forks.sh", "sync-pieroproietti-forks.yml",
    "sync-pieroproietti-forks.yaml", "rebase-lts.sh",
    "rebase-lts.yml", "rebase-lts.yaml",
}

if os.path.basename(path) in PRESERVE_FILES:
    print("UNCHANGED")
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except OSError:
    print("UNCHANGED")
    sys.exit(0)

out = []
modified = False
for line in lines:
    if guard_re.search(line) or preserve_re.search(line):
        out.append(line)
    else:
        new = line
        for src, dst in pairs:
            new = new.replace(src, dst)
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

# Use code search to find files containing a term in an org
# Returns: "repo/path" lines
search_files() {
  local org="$1" term="$2"
  local page=1 results=""
  while true; do
    local resp
    resp=$(api_get "${API}/search/code?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$term")+org:${org}&per_page=100&page=${page}")
    local items count
    items=$(echo "$resp" | jq -r '.items[]? | "\(.repository.name)/\(.path)"' 2>/dev/null)
    count=$(echo "$resp" | jq '.items | length' 2>/dev/null || echo 0)
    results="${results}${items}"$'\n'
    [[ "$count" -lt 100 ]] && break
    (( page++ ))
    sleep 2  # search rate limit: 10 req/min authenticated
  done
  echo "$results" | grep -v '^$' | sort -u
}

# Patch a single file in a repo via the API
patch_file() {
  local org="$1" repo="$2" filepath="$3"
  shift 3
  local pairs=("$@")  # src1 dst1 src2 dst2 ...

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local file_data sha content_b64
  file_data=$(api_get "${API}/repos/${org}/${repo}/contents/${filepath}")
  sha=$(echo "$file_data" | jq -r '.sha // empty')
  content_b64=$(echo "$file_data" | jq -r '.content // empty')
  [[ -z "$sha" || -z "$content_b64" ]] && return

  local tmpfile="${tmpdir}/workfile"
  echo "$content_b64" | base64 -d > "$tmpfile" 2>/dev/null || return

  local status
  status=$(python3 "$PATCHER" "$tmpfile" "${pairs[@]}")
  [[ "$status" != "MODIFIED" ]] && return

  local new_b64 payload http_code
  new_b64=$(base64 -w 0 "$tmpfile")
  payload=$(jq -n \
    --arg msg "ci: rebase org refs [auto]" \
    --arg content "$new_b64" \
    --arg sha "$sha" \
    '{message:$msg, content:$content, sha:$sha}')

  http_code=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    "${API}/repos/${org}/${repo}/contents/${filepath}" -d "$payload")

  if [[ "$http_code" == "200" ]]; then
    echo "    patched: ${repo}/${filepath}"
  else
    echo "    FAILED:  ${repo}/${filepath} (HTTP $http_code)"
  fi
}

# Process all files found by code search for a given org + search term
process_search_results() {
  local org="$1" term="$2"
  shift 2
  local pairs=("$@")

  echo "  Searching ${org} for: ${term}"
  local files
  files=$(search_files "$org" "$term")
  local count
  count=$(echo "$files" | grep -c . || true)
  echo "  Found ${count} file(s)"
  sleep 2

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local repo filepath
    repo="${entry%%/*}"
    filepath="${entry#*/}"
    patch_file "$org" "$repo" "$filepath" "${pairs[@]}"
  done <<< "$files"
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
login=$(api_get "${API}/user" | jq -r '.login // empty')
[[ -z "$login" ]] && { echo "ERROR: GH_TOKEN invalid."; exit 1; }
echo "Authenticated as: $login"
echo ""

# ── Interested-Deving-1896: pieroproietti -> Interested-Deving-1896 ──────────
echo "========================================"
echo "Patching ${UPSTREAM_OWNER}: pieroproietti refs"
echo "========================================"
process_search_results "$UPSTREAM_OWNER" "pieroproietti" \
  "pieroproietti" "$UPSTREAM_OWNER"
echo ""

# ── OSP: Interested-Deving-1896 -> OSP, pieroproietti -> OSP ─────────────────
echo "========================================"
echo "Patching ${OSP_ORG}: upstream + pieroproietti refs"
echo "========================================"
process_search_results "$OSP_ORG" "Interested-Deving-1896" \
  "Interested-Deving-1896" "$OSP_ORG" \
  "pieroproietti" "$OSP_ORG"
sleep 2
process_search_results "$OSP_ORG" "pieroproietti" \
  "Interested-Deving-1896" "$OSP_ORG" \
  "pieroproietti" "$OSP_ORG"
echo ""

# ── OOC: Interested-Deving-1896 -> OOC, OSP -> OOC, pieroproietti -> OOC ─────
echo "========================================"
echo "Patching ${OOC_ORG}: upstream + OSP + pieroproietti refs"
echo "========================================"
for term in "Interested-Deving-1896" "OpenOS-Project-OSP" "pieroproietti"; do
  process_search_results "$OOC_ORG" "$term" \
    "Interested-Deving-1896" "$OOC_ORG" \
    "OpenOS-Project-OSP"     "$OOC_ORG" \
    "pieroproietti"          "$OOC_ORG"
  sleep 2
done
echo ""

echo "========================================"
echo "Reconciliation complete."
echo "========================================"
