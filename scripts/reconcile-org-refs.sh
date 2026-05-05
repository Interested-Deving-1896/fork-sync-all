#!/usr/bin/env bash
# reconcile-org-refs.sh
#
# For every repo that exists in BOTH OSP and Interested-Deving-1896:
#   - In the Interested-Deving-1896 copy: replace pieroproietti → Interested-Deving-1896
#   - In the OSP copy:                    replace Interested-Deving-1896 → OSP, pieroproietti → OSP
#   - In the OOC copy (if it exists):     replace Interested-Deving-1896 → OOC, OSP → OOC, pieroproietti → OOC
#
# Skips:
#   - Lines containing `if: github.repository ==`  (workflow guards — must stay as-is)
#   - polkit/D-Bus action IDs (com.github.pieroproietti.*)
#   - Binary files, lockfiles, and files >1 MB
#
# Uses GitHub code search to find only files that actually contain the target
# strings, then patches only those files via the Contents API.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"

API="https://api.github.com"
AUTH="Authorization: token ${GH_TOKEN}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

api_get() { curl -sf -H "$AUTH" -H "Accept: application/vnd.github+json" "$@"; }
api_put() { curl -sf -X PUT -H "$AUTH" -H "Accept: application/vnd.github+json" \
              -H "Content-Type: application/json" "$@"; }

rate_wait() {
  local remaining reset now wait_sec
  remaining=$(curl -sf -H "$AUTH" "$API/rate_limit" | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])")
  if [ "$remaining" -lt 50 ]; then
    reset=$(curl -sf -H "$AUTH" "$API/rate_limit" | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['reset'])")
    now=$(date +%s)
    wait_sec=$(( reset - now + 5 ))
    echo "  [rate-limit] only $remaining requests left — sleeping ${wait_sec}s"
    sleep "$wait_sec"
  fi
}

search_wait() {
  # code search: 10 req/min
  sleep 7
}

# Validate token via /rate_limit (immune to secondary rate limits)
echo "Validating token..."
REMAINING=$(api_get "$API/rate_limit" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" 2>/dev/null || true)
if [ -z "$REMAINING" ]; then
  echo "ERROR: GH_TOKEN invalid or unreachable."
  exit 1
fi
echo "Token valid. Core API requests remaining: $REMAINING"

# ---------------------------------------------------------------------------
# Python patcher (written once, reused for every file)
# ---------------------------------------------------------------------------
PATCHER=$(mktemp /tmp/patcher.XXXXXX.py)
cat > "$PATCHER" << 'PYEOF'
import sys, re

src_str  = sys.argv[1]
dst_str  = sys.argv[2]
content  = sys.stdin.read()
lines    = content.splitlines(keepends=True)
out      = []
changed  = False

for line in lines:
    # Never touch workflow repository guards
    if 'if: github.repository ==' in line:
        out.append(line)
        continue
    # Never touch polkit/D-Bus action IDs
    if re.search(r'com\.github\.pieroproietti', line):
        out.append(line)
        continue
    new_line = line.replace(src_str, dst_str)
    if new_line != line:
        changed = True
    out.append(new_line)

if changed:
    sys.stdout.write(''.join(out))
    sys.exit(0)
else:
    sys.exit(2)   # no changes — caller skips the PUT
PYEOF

# ---------------------------------------------------------------------------
# Skip list — files we never patch
# ---------------------------------------------------------------------------
SKIP_EXTENSIONS="lock|sum|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|bin|exe|so|dylib|zip|tar|gz|bz2|xz|zst"

should_skip() {
  local path="$1"
  local ext="${path##*.}"
  echo "$ext" | grep -qE "^($SKIP_EXTENSIONS)$"
}

# ---------------------------------------------------------------------------
# patch_file  <owner> <repo> <path> <src> <dst>
# ---------------------------------------------------------------------------
patch_file() {
  local owner="$1" repo="$2" fpath="$3" src="$4" dst="$5"

  should_skip "$fpath" && return 0

  rate_wait

  local meta
  meta=$(api_get "$API/repos/$owner/$repo/contents/$fpath" 2>/dev/null) || return 0

  # Use temp files throughout — never pass large content as shell arguments
  local tmp_meta tmp_decoded tmp_patched tmp_payload
  tmp_meta=$(mktemp /tmp/meta.XXXXXX.json)
  echo "$meta" > "$tmp_meta"

  local size encoding
  size=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('size',0))" "$tmp_meta")
  encoding=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('encoding',''))" "$tmp_meta")

  if [ "$size" -gt 1048576 ] || [ "$encoding" != "base64" ]; then
    rm -f "$tmp_meta"
    return 0
  fi

  local sha
  sha=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1]))['sha'])" "$tmp_meta")

  tmp_decoded=$(mktemp /tmp/decoded.XXXXXX)
  python3 -c "
import sys, json, base64
data = json.load(open(sys.argv[1]))
content = base64.b64decode(data['content'].replace('\n',''))
open(sys.argv[2], 'wb').write(content)
" "$tmp_meta" "$tmp_decoded" || { rm -f "$tmp_meta" "$tmp_decoded"; return 0; }

  tmp_patched=$(mktemp /tmp/patched.XXXXXX)
  local rc=0
  python3 "$PATCHER" "$src" "$dst" < "$tmp_decoded" > "$tmp_patched" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # rc=2 means no changes needed; any other non-zero is also non-fatal
    rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched"
    return 0
  fi

  tmp_payload=$(mktemp /tmp/payload.XXXXXX.json)
  python3 -c "
import sys, json, base64
patched = open(sys.argv[1], 'rb').read()
new_b64 = base64.b64encode(patched).decode()
print(json.dumps({
  'message': 'ci: reconcile org refs (%s -> %s)' % (sys.argv[3], sys.argv[4]),
  'content': new_b64,
  'sha':     sys.argv[2]
}))
" "$tmp_patched" "$sha" "$src" "$dst" > "$tmp_payload"

  api_put "$API/repos/$owner/$repo/contents/$fpath" -d "@$tmp_payload" > /dev/null \
    && echo "    patched: $fpath" \
    || echo "    WARN: failed to patch $fpath"

  rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched" "$tmp_payload"
}

# ---------------------------------------------------------------------------
# search_and_patch  <owner> <repo> <search_term> <src> <dst>
# ---------------------------------------------------------------------------
search_and_patch() {
  local owner="$1" repo="$2" term="$3" src="$4" dst="$5"

  search_wait
  rate_wait

  local results
  results=$(curl -sf -H "$AUTH" -H "Accept: application/vnd.github+json" \
    "$API/search/code?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$term")+repo:$owner/$repo&per_page=100" \
    2>/dev/null) || return 0

  local count
  count=$(echo "$results" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ] && return 0

  echo "  [$owner/$repo] found $count file(s) containing '$term'"

  echo "$results" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['path'])
" | while read -r fpath; do
    patch_file "$owner" "$repo" "$fpath" "$src" "$dst"
  done
}

# ---------------------------------------------------------------------------
# repo_exists  <owner> <repo>
# ---------------------------------------------------------------------------
repo_exists() {
  local owner="$1" repo="$2"
  api_get "$API/repos/$owner/$repo" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Main loop — iterate over OSP repos, process only those also in UPSTREAM
# ---------------------------------------------------------------------------
echo ""
echo "Fetching OSP repo list..."
OSP_REPOS=$(api_get "$API/orgs/$OSP_ORG/repos?per_page=100&type=all" | \
  python3 -c "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]" 2>/dev/null || true)

if [ -z "$OSP_REPOS" ]; then
  # Fallback: GraphQL (handles user accounts too)
  OSP_REPOS=$(curl -sf -H "Authorization: bearer $GH_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "$API/graphql" \
    -d '{"query":"{ organization(login: \"'"$OSP_ORG"'\") { repositories(first: 100) { nodes { name } } } }"}' | \
    python3 -c "import sys,json; d=json.load(sys.stdin); [print(n['name']) for n in d['data']['organization']['repositories']['nodes']]")
fi

echo "OSP repos found: $(echo "$OSP_REPOS" | wc -l)"
echo ""

for REPO in $OSP_REPOS; do
  # Skip fork-sync-all itself to avoid self-modification loops
  [ "$REPO" = "fork-sync-all" ] && continue

  # Only process repos that also exist in Interested-Deving-1896
  if ! repo_exists "$UPSTREAM_OWNER" "$REPO"; then
    echo "[$REPO] not in $UPSTREAM_OWNER — skipping"
    continue
  fi

  echo "=== $REPO ==="

  # --- Interested-Deving-1896 copy: pieroproietti → UPSTREAM_OWNER ---
  search_and_patch "$UPSTREAM_OWNER" "$REPO" "pieroproietti" "pieroproietti" "$UPSTREAM_OWNER"

  # --- OSP copy: Interested-Deving-1896 → OSP, pieroproietti → OSP ---
  search_and_patch "$OSP_ORG" "$REPO" "$UPSTREAM_OWNER" "$UPSTREAM_OWNER" "$OSP_ORG"
  search_and_patch "$OSP_ORG" "$REPO" "pieroproietti"   "pieroproietti"   "$OSP_ORG"

  # --- OOC copy (if it exists): all three → OOC ---
  if repo_exists "$OOC_ORG" "$REPO"; then
    search_and_patch "$OOC_ORG" "$REPO" "$UPSTREAM_OWNER" "$UPSTREAM_OWNER" "$OOC_ORG"
    search_and_patch "$OOC_ORG" "$REPO" "$OSP_ORG"        "$OSP_ORG"        "$OOC_ORG"
    search_and_patch "$OOC_ORG" "$REPO" "pieroproietti"    "pieroproietti"   "$OOC_ORG"
  fi

  echo ""
done

rm -f "$PATCHER"

# ---------------------------------------------------------------------------
# Label conversion — rewrite OSP/OOC org names in build + compile + install
# commands so Interested-Deving-1896 repos reference themselves, not mirrors.
#
# Patterns covered:
#   ghcr.io/openOS-Project-OSP/...   → ghcr.io/Interested-Deving-1896/...
#   ghcr.io/openOS-Project-Ecosystem-OOC/... → ghcr.io/Interested-Deving-1896/...
#   docker pull/run/push <mirror-org>/...    → .../Interested-Deving-1896/...
#   github.com/<mirror-org>/...              → github.com/Interested-Deving-1896/...
#   pip install git+https://github.com/<mirror-org>/...
#   go get github.com/<mirror-org>/...
#   cargo add --git https://github.com/<mirror-org>/...
#   npm/yarn/pnpm add <mirror-org>/...  (GitHub shorthand)
#   Any remaining bare <mirror-org>/ references in shell scripts / Makefiles
#
# Skips:
#   - workflow repository guards (if: github.repository ==)
#   - binary / lockfiles (same skip list as above)
#   - Lines that already contain UPSTREAM_OWNER (already correct)
# ---------------------------------------------------------------------------

BUILD_PATCHER=$(mktemp /tmp/build_patcher.XXXXXX.py)
cat > "$BUILD_PATCHER" << 'PYEOF'
import sys, re

mirror_orgs = sys.argv[1].split(',')   # e.g. "OpenOS-Project-OSP,OpenOS-Project-Ecosystem-OOC"
upstream    = sys.argv[2]              # Interested-Deving-1896
content     = sys.stdin.read()
lines       = content.splitlines(keepends=True)
out         = []
changed     = False

# Patterns that indicate a build/install/registry context
BUILD_PATTERNS = [
    r'ghcr\.io/',
    r'docker\s+(pull|run|push|build|tag)',
    r'pip\s+install',
    r'pip3\s+install',
    r'go\s+get',
    r'go\s+install',
    r'cargo\s+add',
    r'cargo\s+install',
    r'npm\s+(install|add|i)\b',
    r'yarn\s+add',
    r'pnpm\s+add',
    r'apt(-get)?\s+install',
    r'apk\s+add',
    r'dnf\s+install',
    r'yum\s+install',
    r'pacman\s+-S',
    r'make\b',
    r'cmake\b',
    r'Makefile',
    r'Dockerfile',
    r'FROM\s+',
    r'COPY\s+--from=',
    r'image:\s+',
    r'container:\s+',
    r'uses:\s+',
    r'git\+https://',
    r'github\.com/',
    r'raw\.githubusercontent\.com/',
]

build_re = re.compile('|'.join(BUILD_PATTERNS), re.IGNORECASE)

for line in lines:
    # Never touch workflow repository guards
    if 'if: github.repository ==' in line:
        out.append(line)
        continue
    # Only process lines that look like build/install/registry context
    if not build_re.search(line):
        out.append(line)
        continue
    new_line = line
    for mirror in mirror_orgs:
        new_line = new_line.replace(mirror, upstream)
        # Also handle lowercase variants (ghcr.io lowercases org names)
        new_line = new_line.replace(mirror.lower(), upstream.lower())
    if new_line != line:
        changed = True
    out.append(new_line)

if changed:
    sys.stdout.write(''.join(out))
    sys.exit(0)
else:
    sys.exit(2)
PYEOF

patch_build_file() {
  local owner="$1" repo="$2" fpath="$3"

  should_skip "$fpath" && return 0

  rate_wait

  local meta
  meta=$(api_get "$API/repos/$owner/$repo/contents/$fpath" 2>/dev/null) || return 0

  local tmp_meta tmp_decoded tmp_patched tmp_payload
  tmp_meta=$(mktemp /tmp/meta.XXXXXX.json)
  echo "$meta" > "$tmp_meta"

  local size encoding
  size=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('size',0))" "$tmp_meta")
  encoding=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('encoding',''))" "$tmp_meta")

  if [ "$size" -gt 1048576 ] || [ "$encoding" != "base64" ]; then
    rm -f "$tmp_meta"; return 0
  fi

  local sha
  sha=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1]))['sha'])" "$tmp_meta")

  tmp_decoded=$(mktemp /tmp/decoded.XXXXXX)
  python3 -c "
import sys, json, base64
data = json.load(open(sys.argv[1]))
content = base64.b64decode(data['content'].replace('\n',''))
open(sys.argv[2], 'wb').write(content)
" "$tmp_meta" "$tmp_decoded" || { rm -f "$tmp_meta" "$tmp_decoded"; return 0; }

  tmp_patched=$(mktemp /tmp/patched.XXXXXX)
  local rc=0
  python3 "$BUILD_PATCHER" "${OSP_ORG},${OOC_ORG}" "$UPSTREAM_OWNER" \
    < "$tmp_decoded" > "$tmp_patched" || rc=$?

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched"; return 0
  fi

  tmp_payload=$(mktemp /tmp/payload.XXXXXX.json)
  python3 -c "
import sys, json, base64
patched = open(sys.argv[1], 'rb').read()
new_b64 = base64.b64encode(patched).decode()
print(json.dumps({
  'message': 'ci: rewrite mirror org refs in build/install commands',
  'content': new_b64,
  'sha':     sys.argv[2]
}))
" "$tmp_patched" "$sha" > "$tmp_payload"

  api_put "$API/repos/$owner/$repo/contents/$fpath" -d "@$tmp_payload" > /dev/null \
    && echo "    patched (build): $fpath" \
    || echo "    WARN: failed to patch $fpath"

  rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched" "$tmp_payload"
}

search_and_patch_build() {
  local owner="$1" repo="$2" term="$3"

  search_wait
  rate_wait

  local results
  results=$(curl -sf -H "$AUTH" -H "Accept: application/vnd.github+json" \
    "$API/search/code?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$term")+repo:$owner/$repo&per_page=100" \
    2>/dev/null) || return 0

  local count
  count=$(echo "$results" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ] && return 0

  echo "  [$owner/$repo] build-label: found $count file(s) containing '$term'"

  echo "$results" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['path'])
" | while read -r fpath; do
    patch_build_file "$owner" "$repo" "$fpath"
  done
}

# ---------------------------------------------------------------------------
# Label conversion pass — Interested-Deving-1896 repos only
# Runs after the org-ref pass so both are applied in one workflow execution.
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  Label conversion pass (build/install/registry refs)"
echo "========================================================"
echo ""

for REPO in $OSP_REPOS; do
  [ "$REPO" = "fork-sync-all" ] && continue
  ! repo_exists "$UPSTREAM_OWNER" "$REPO" && continue

  echo "=== $REPO (label conversion) ==="
  # Search for OSP and OOC org names in build-context files
  search_and_patch_build "$UPSTREAM_OWNER" "$REPO" "$OSP_ORG"
  search_and_patch_build "$UPSTREAM_OWNER" "$REPO" "$OOC_ORG"
  echo ""
done

rm -f "$BUILD_PATCHER"
echo "Done."
