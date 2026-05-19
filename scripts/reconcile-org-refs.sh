#!/usr/bin/env bash
# reconcile-org-refs.sh
#
# For every repo that exists in BOTH OSP and Interested-Deving-1896:
#   - In the Interested-Deving-1896 copy: replace pieroproietti → Interested-Deving-1896
#
# OSP and OOC are NOT patched directly. The mirror chain (mirror-to-osp at :00,
# mirror-osp-to-ooc at :15) propagates commits from Interested-Deving-1896 to
# OSP and OOC automatically. Committing directly to mirrors caused them to diverge
# from the source of truth and triggered the upstream-commits detection loop.
#
# Skips:
#   - Lines containing `if: github.repository ==`  (workflow guards — must stay as-is)
#   - polkit/D-Bus action IDs (com.github.pieroproietti.*)
#   - Binary files, lockfiles, and files >1 MB
#
# Uses GitHub code search to find only files that actually contain the target
# strings, then patches only those files via the Contents API.
#
# GitLab pass (third pass — requires GITLAB_TOKEN):
#   For each repo on gitlab.com/openos-project/{subgroup}/{repo}, rewrites
#   self-referential GitHub URLs to their GitLab equivalents:
#     github.com/OpenOS-Project-OSP/{repo}            → gitlab.com/openos-project/{subgroup}/{repo}
#     github.com/Interested-Deving-1896/{repo}        → gitlab.com/openos-project/{subgroup}/{repo}
#     github.com/OpenOS-Project-Ecosystem-OOC/{repo}  → gitlab.com/openos-project/{subgroup}/{repo}
#   Third-party github.com links (upstream projects) are left untouched.
#   Subgroup map is loaded from config/gitlab-subgroups.yml (single source of truth).
#   If GITLAB_TOKEN is absent the pass is skipped non-fatally.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"
# GITLAB_TOKEN is optional — GitLab pass is skipped if absent
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

# ORGS_FILTER controls which passes run (from workflow_dispatch input):
#   all          — run all three passes (default)
#   osp-only     — org-ref + label passes only (no GitLab pass)
#   ooc-only     — org-ref + label passes only (no GitLab pass)
#   gitlab-only  — GitLab pass only
ORGS_FILTER="${ORGS_FILTER:-all}"
# REPO_FILTER: substring — only process repos whose name contains this string
REPO_FILTER="${REPO_FILTER:-}"
# DRY_RUN: print what would change without writing anything
DRY_RUN="${DRY_RUN:-false}"

[[ "$ORGS_FILTER" != "all" ]] && echo "Orgs filter: ${ORGS_FILTER}"
[[ -n "$REPO_FILTER" ]]       && echo "Repo filter: ${REPO_FILTER}"
[[ "$DRY_RUN" == "true" ]]    && echo "Dry run:     no changes will be written"

API="https://api.github.com"
AUTH="Authorization: token ${GH_TOKEN}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

api_get() { curl -sf -H "$AUTH" -H "Accept: application/vnd.github+json" "$@"; }
api_put() { curl -sf -X PUT -H "$AUTH" -H "Accept: application/vnd.github+json" \
              -H "Content-Type: application/json" "$@"; }

rate_wait() {
  local remaining reset now wait_sec rate_json
  # Suppress errors — a transient curl/parse failure should not abort the run
  rate_json=$(curl -sf -H "$AUTH" "$API/rate_limit" 2>/dev/null || true)
  remaining=$(echo "$rate_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo "100")
  if [ "$remaining" -lt 50 ]; then
    reset=$(echo "$rate_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['resources']['core']['reset'])" 2>/dev/null || echo "0")
    now=$(date +%s)
    wait_sec=$(( reset - now + 5 ))
    if [ "$wait_sec" -gt 0 ]; then
      echo "  [rate-limit] only $remaining requests left — sleeping ${wait_sec}s"
      sleep "$wait_sec"
    fi
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

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    DRY  would patch: $fpath (${src} → ${dst})"
  else
    api_put "$API/repos/$owner/$repo/contents/$fpath" -d "@$tmp_payload" > /dev/null \
      && echo "    patched: $fpath" \
      || echo "    WARN: failed to patch $fpath"
  fi

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
if [[ "$ORGS_FILTER" == "gitlab-only" ]]; then
  echo "Skipping org-ref and label passes (orgs filter: gitlab-only)."
  OSP_REPOS=""
else

echo ""
echo "Fetching OSP repo list..."
OSP_REPOS=""
_page=1
while true; do
  _batch=$(api_get "$API/orgs/$OSP_ORG/repos?per_page=100&page=${_page}&type=all" | \
    python3 -c "import sys,json; repos=json.load(sys.stdin); [print(r['name']) for r in repos]; print('__COUNT__'+str(len(repos)),end='')" \
    2>/dev/null || true)
  _count=$(echo "$_batch" | grep -o '__COUNT__[0-9]*' | grep -o '[0-9]*' || echo 0)
  _names=$(echo "$_batch" | grep -v '__COUNT__')
  OSP_REPOS="${OSP_REPOS}${_names}"$'\n'
  [[ "$_count" -lt 100 ]] && break
  (( _page++ ))
done
OSP_REPOS=$(echo "$OSP_REPOS" | grep -v '^$' || true)

if [ -z "$OSP_REPOS" ]; then
  # Fallback: GraphQL with pagination (handles user accounts too)
  _cursor=""
  while true; do
    _after=$( [[ -n "$_cursor" ]] && echo ", after: \"${_cursor}\"" || echo "" )
    _gql_result=$(curl -sf -H "Authorization: bearer $GH_TOKEN" \
      -H "Content-Type: application/json" \
      -X POST "$API/graphql" \
      -d "{\"query\":\"{ organization(login: \\\"${OSP_ORG}\\\") { repositories(first: 100${_after}) { nodes { name } pageInfo { hasNextPage endCursor } } } }\"}" \
      2>/dev/null || true)
    _batch_names=$(echo "$_gql_result" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); [print(n['name']) for n in d['data']['organization']['repositories']['nodes']]" \
      2>/dev/null || true)
    OSP_REPOS="${OSP_REPOS}${_batch_names}"$'\n'
    _has_next=$(echo "$_gql_result" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d['data']['organization']['repositories']['pageInfo']['hasNextPage'])" \
      2>/dev/null || echo "False")
    [[ "$_has_next" != "True" ]] && break
    _cursor=$(echo "$_gql_result" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d['data']['organization']['repositories']['pageInfo']['endCursor'])" \
      2>/dev/null || true)
    [[ -z "$_cursor" ]] && break
  done
  OSP_REPOS=$(echo "$OSP_REPOS" | grep -v '^$' || true)
fi

echo "OSP repos found: $(echo "$OSP_REPOS" | wc -l)"
echo ""

for REPO in $OSP_REPOS; do
  # Skip fork-sync-all itself to avoid self-modification loops
  [ "$REPO" = "fork-sync-all" ] && continue

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$REPO" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  # Only process repos that also exist in Interested-Deving-1896
  if ! repo_exists "$UPSTREAM_OWNER" "$REPO"; then
    echo "[$REPO] not in $UPSTREAM_OWNER — skipping"
    continue
  fi

  echo "=== $REPO ==="

  # Only patch Interested-Deving-1896 — the mirror chain (mirror-to-osp at :00,
  # mirror-osp-to-ooc at :15) propagates these commits to OSP and OOC automatically.
  # Committing directly to OSP/OOC caused mirrors to diverge from the source of truth
  # and triggered the upstream-commits loop (mirror-side commits detected as "new").
  search_and_patch "$UPSTREAM_OWNER" "$REPO" "pieroproietti" "pieroproietti" "$UPSTREAM_OWNER"

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

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    DRY  would patch (build): $fpath"
  else
    api_put "$API/repos/$owner/$repo/contents/$fpath" -d "@$tmp_payload" > /dev/null \
      && echo "    patched (build): $fpath" \
      || echo "    WARN: failed to patch $fpath"
  fi

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
  [[ -n "$REPO_FILTER" && "$REPO" != *"$REPO_FILTER"* ]] && continue
  ! repo_exists "$UPSTREAM_OWNER" "$REPO" && continue

  echo "=== $REPO (label conversion) ==="
  # Search for OSP and OOC org names in build-context files
  search_and_patch_build "$UPSTREAM_OWNER" "$REPO" "$OSP_ORG"
  search_and_patch_build "$UPSTREAM_OWNER" "$REPO" "$OOC_ORG"
  echo ""
done

rm -f "$BUILD_PATCHER"

fi  # end: [[ "$ORGS_FILTER" != "gitlab-only" ]]

# ---------------------------------------------------------------------------
# GitLab pass — rewrite GitHub org URLs to their gitlab.com equivalents
#
# OSP content arrives on GitLab already clean of GitHub org refs (the passes
# above run before mirror-osp-to-gitlab). However repos can accumulate
# self-referential URLs that point to github.com/OpenOS-Project-OSP/... or
# github.com/Interested-Deving-1896/... — clone instructions, README badges,
# install scripts, CI status links. Those need rewriting to their
# gitlab.com/openos-project/{subgroup}/{repo} equivalents.
#
# Subgroup map mirrors the one in scripts/mirror-osp-to-gitlab.sh exactly.
# Both must be kept in sync if the GitLab group structure changes.
#
# Required env vars (in addition to those already validated above):
#   GITLAB_TOKEN  — GitLab PAT with api + write_repository scope
#
# If GITLAB_TOKEN is absent the pass is skipped non-fatally (same pattern
# as mirror-osp-to-gitlab.sh).
# ---------------------------------------------------------------------------

if [[ "$ORGS_FILTER" == "osp-only" || "$ORGS_FILTER" == "ooc-only" ]]; then
  echo ""
  echo "Skipping GitLab pass (orgs filter: ${ORGS_FILTER})."
  echo "Done."
  exit 0
fi

if [ -z "${GITLAB_TOKEN:-}" ]; then
  echo ""
  echo "GITLAB_TOKEN not set — skipping GitLab reconcile pass."
  echo "Done."
  exit 0
fi

GL_API="https://gitlab.com/api/v4"
GL_AUTH="PRIVATE-TOKEN: ${GITLAB_TOKEN}"

# Subgroup map — loaded from config/gitlab-subgroups.yml (single source of truth)
_RECONCILE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GL_SUBGROUP_CONFIG="${_RECONCILE_SCRIPT_DIR}/../config/gitlab-subgroups.yml"

if [[ ! -f "${GL_SUBGROUP_CONFIG}" ]]; then
  echo "ERROR: ${GL_SUBGROUP_CONFIG} not found — skipping GitLab pass." >&2
  echo "Done."
  exit 0
fi

# gl_namespace_path <repo_name>
# Prints the full GitLab namespace path: openos-project/{subgroup}/{repo}
gl_namespace_path() {
  python3 - "$1" "${GL_SUBGROUP_CONFIG}" << 'PYEOF'
import sys, re

repo   = sys.argv[1]
config = sys.argv[2]

with open(config) as f:
    content = f.read()

current_sg = None
current_id = None
default_sg = None

for line in content.splitlines():
    m = re.match(r'^default_subgroup:\s*(\S+)', line)
    if m:
        default_sg = m.group(1); continue
    m = re.match(r'^  (\S+):$', line)
    if m:
        current_sg = m.group(1); current_id = None; continue
    m = re.match(r'^\s+id:\s*(\d+)', line)
    if m and current_sg:
        current_id = int(m.group(1)); continue
    m = re.match(r'^\s+-\s+(\S+)', line)
    if m and current_sg and current_id is not None:
        if m.group(1) == repo:
            print(f"openos-project/{current_sg}/{repo}")
            sys.exit(0)

print(f"openos-project/{default_sg or 'ops'}/{repo}")
PYEOF
}

gl_api_get() {
  curl -sf -H "$GL_AUTH" "$@"
}

gl_api_put() {
  curl -sf -X PUT -H "$GL_AUTH" -H "Content-Type: application/json" "$@"
}

gl_rate_wait() {
  # GitLab: 2000 req/min. Sleep briefly between file operations.
  sleep 1
}

# Search GitLab project for files containing a string
# Uses the repository search API (no separate code-search quota)
gl_search_files() {
  local project_id="$1" term="$2"
  local encoded_term
  encoded_term=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$term")
  gl_api_get "${GL_API}/projects/${project_id}/search?scope=blobs&search=${encoded_term}&per_page=100" \
    2>/dev/null \
    | python3 -c "
import sys, json
results = json.load(sys.stdin)
if isinstance(results, list):
    seen = set()
    for r in results:
        p = r.get('path') or r.get('filename','')
        if p and p not in seen:
            seen.add(p)
            print(p)
" 2>/dev/null || true
}

# Patch a single file in a GitLab project
gl_patch_file() {
  local project_id="$1" fpath="$2" src="$3" dst="$4" branch="${5:-main}"

  should_skip "$fpath" && return 0

  gl_rate_wait

  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$fpath")

  local meta
  meta=$(gl_api_get "${GL_API}/projects/${project_id}/repository/files/${encoded_path}?ref=${branch}" \
    2>/dev/null) || return 0

  local tmp_meta tmp_decoded tmp_patched tmp_payload
  tmp_meta=$(mktemp /tmp/gl_meta.XXXXXX.json)
  echo "$meta" > "$tmp_meta"

  local size encoding
  size=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('size',0))" "$tmp_meta" 2>/dev/null || echo 0)
  encoding=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1])).get('encoding',''))" "$tmp_meta" 2>/dev/null || echo "")

  if [ "$size" -gt 1048576 ] || [ "$encoding" != "base64" ]; then
    rm -f "$tmp_meta"; return 0
  fi

  tmp_decoded=$(mktemp /tmp/gl_decoded.XXXXXX)
  python3 -c "
import sys, json, base64
data = json.load(open(sys.argv[1]))
content = base64.b64decode(data['content'].replace('\n',''))
open(sys.argv[2], 'wb').write(content)
" "$tmp_meta" "$tmp_decoded" || { rm -f "$tmp_meta" "$tmp_decoded"; return 0; }

  tmp_patched=$(mktemp /tmp/gl_patched.XXXXXX)
  local rc=0
  python3 "$PATCHER" "$src" "$dst" < "$tmp_decoded" > "$tmp_patched" || rc=$?

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched"
    return 0
  fi

  tmp_payload=$(mktemp /tmp/gl_payload.XXXXXX.json)
  python3 -c "
import sys, json, base64
patched = open(sys.argv[1], 'rb').read()
new_b64 = base64.b64encode(patched).decode()
print(json.dumps({
  'branch':         sys.argv[2],
  'content':        new_b64,
  'encoding':       'base64',
  'commit_message': 'ci: reconcile org refs (%s -> %s)' % (sys.argv[3], sys.argv[4])
}))
" "$tmp_patched" "$branch" "$src" "$dst" > "$tmp_payload"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    DRY  would gl patch: $fpath (${src} → ${dst})"
  else
    gl_api_put \
      "${GL_API}/projects/${project_id}/repository/files/${encoded_path}" \
      -d "@$tmp_payload" > /dev/null \
      && echo "    gl patched: $fpath" \
      || echo "    WARN: failed to gl patch $fpath"
  fi

  rm -f "$tmp_meta" "$tmp_decoded" "$tmp_patched" "$tmp_payload"
}

gl_search_and_patch() {
  local project_id="$1" term="$2" src="$3" dst="$4" branch="${5:-main}"

  local files
  mapfile -t files < <(gl_search_files "$project_id" "$term")
  [ "${#files[@]}" -eq 0 ] && return 0

  echo "  [gl:${project_id}] found ${#files[@]} file(s) containing '${term}'"
  for fpath in "${files[@]}"; do
    gl_patch_file "$project_id" "$fpath" "$src" "$dst" "$branch"
  done
}

# Get GitLab project ID for a namespace path
gl_project_id() {
  local ns_path="$1"
  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$ns_path")
  gl_api_get "${GL_API}/projects/${encoded}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true
}

# Get default branch for a GitLab project
gl_default_branch() {
  local project_id="$1"
  gl_api_get "${GL_API}/projects/${project_id}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null \
    || echo "main"
}

echo ""
echo "========================================================"
echo "  GitLab reconcile pass (GitHub URLs → GitLab paths)"
echo "========================================================"
echo ""

for REPO in $OSP_REPOS; do
  [ "$REPO" = "fork-sync-all" ] && continue
  [[ -n "$REPO_FILTER" && "$REPO" != *"$REPO_FILTER"* ]] && continue

  # Only process repos that exist in I-D-1896 (same filter as GitHub passes)
  if ! repo_exists "$UPSTREAM_OWNER" "$REPO"; then
    continue
  fi

  # Derive GitLab namespace path and get project ID
  GL_NS_PATH=$(gl_namespace_path "$REPO")
  GL_PROJECT_ID=$(gl_project_id "$GL_NS_PATH")

  if [ -z "$GL_PROJECT_ID" ]; then
    echo "[$REPO] not found on GitLab at ${GL_NS_PATH} — skipping"
    continue
  fi

  GL_BRANCH=$(gl_default_branch "$GL_PROJECT_ID")
  GL_SELF_URL="gitlab.com/${GL_NS_PATH}"

  echo "=== $REPO (GitLab: ${GL_NS_PATH}) ==="

  # Rewrite github.com/OpenOS-Project-OSP/{repo} → gitlab.com/{subgroup}/{repo}
  # Only rewrite self-references (this repo), not third-party GitHub links
  gl_search_and_patch "$GL_PROJECT_ID" \
    "github.com/${OSP_ORG}/${REPO}" \
    "github.com/${OSP_ORG}/${REPO}" \
    "${GL_SELF_URL}" \
    "$GL_BRANCH"

  # Rewrite github.com/Interested-Deving-1896/{repo} → gitlab.com/{subgroup}/{repo}
  gl_search_and_patch "$GL_PROJECT_ID" \
    "github.com/${UPSTREAM_OWNER}/${REPO}" \
    "github.com/${UPSTREAM_OWNER}/${REPO}" \
    "${GL_SELF_URL}" \
    "$GL_BRANCH"

  # Rewrite github.com/OpenOS-Project-Ecosystem-OOC/{repo} → gitlab.com/{subgroup}/{repo}
  gl_search_and_patch "$GL_PROJECT_ID" \
    "github.com/${OOC_ORG}/${REPO}" \
    "github.com/${OOC_ORG}/${REPO}" \
    "${GL_SELF_URL}" \
    "$GL_BRANCH"

  echo ""
done

echo "Done."


