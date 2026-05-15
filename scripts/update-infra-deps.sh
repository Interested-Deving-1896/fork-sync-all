#!/usr/bin/env bash
#
# Scan all GitHub Actions workflow files across SCAN_OWNERS and open PRs for
# outdated infrastructure dependencies. One PR per repo, idempotent.
#
# What is scanned:
#   GitHub Actions versions  — uses: owner/action@vN
#     Checks the latest release tag. Flags if the action's node runtime is
#     deprecated (node16 → EOL, node20 → EOL April 2026).
#   Runner images            — runs-on: ubuntu-XX.XX
#     Flags pinned versions past their Ubuntu EOL date.
#   Node.js versions         — node-version: N (in setup-node steps)
#     Flags versions past their EOL date per endoflife.date.
#   Python versions          — python-version: X.Y (in setup-python steps)
#     Flags versions past their EOL date per endoflife.date.
#   Raw GitHub URL pins      — raw.githubusercontent.com/<owner>/<repo>/<tag>/
#     Scanned in workflow files and devcontainer files. Checks the latest
#     release tag for the referenced repo and flags if a newer one exists.
#   Devcontainer feature versions — "version": "X.Y.Z" in devcontainer-feature.json
#     Checks the upstream repo's latest release and flags if outdated.
#
# For each repo with at least one outdated dependency:
#   1. Create branch deps/update-infra-YYYY-MM-DD (skip if already open PR).
#   2. Commit updated workflow files to that branch.
#   3. Open a PR against the repo's default branch.
#
# Requires:
#   GH_TOKEN     — PAT with repo + workflow + pull_request scopes on all SCAN_OWNERS
#   SCAN_OWNERS  — space-separated org/user names to scan
#                  Defaults (set in update-infra-deps.yml) to all three orgs:
#                  Interested-Deving-1896 OpenOS-Project-OSP OpenOS-Project-Ecosystem-OOC
#                  This means fork-sync-all itself is always scanned.
#
# Optional:
#   DRY_RUN      — set to "true" to print changes without creating branches/PRs
#   EOL_WINDOW   — days before EOL to start flagging (default: 90)
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SCAN_OWNERS:?SCAN_OWNERS is required}"

DRY_RUN="${DRY_RUN:-false}"
EOL_WINDOW="${EOL_WINDOW:-90}"

API="https://api.github.com"
EOL_API="https://endoflife.date/api"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
HEADER_FILE=$(mktemp)
TODAY=$(date -u +%Y-%m-%d)
BRANCH_DATE=$(date -u +%Y-%m-%d)
PR_BRANCH="deps/update-infra-${BRANCH_DATE}"

trap 'rm -f "$HEADER_FILE"' EXIT

repos_scanned=0
repos_updated=0
prs_opened=0
prs_skipped=0

# ── API helpers ───────────────────────────────────────────────────────────────

sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

api_get() {
  local url="$1"; shift
  local response http_code body attempt=0
  while true; do
    response=$(curl --disable --silent -w "\n%{http_code}" \
      "${AUTH[@]}" -D "$HEADER_FILE" "$url" "$@" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ ))
      [[ $attempt -gt 3 ]] && { echo "$body"; return 1; }
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s)
      wait=$(( ${reset:-0} - now + 5 ))
      [[ $wait -gt 0 && $wait -lt 3700 ]] && sleep "$wait" || sleep 60
      continue
    fi
    echo "$body"
    return 0
  done
}

api_post() {
  local url="$1" data="$2"
  curl --disable --silent -X POST "${AUTH[@]}" \
    -H "Content-Type: application/json" --data "$data" "$url"
}

api_put() {
  local url="$1" data="$2"
  curl --disable --silent -X PUT "${AUTH[@]}" \
    -H "Content-Type: application/json" --data "$data" "$url"
}

# ── EOL data (fetched once, cached in variables) ──────────────────────────────

NODE_EOL_JSON=""
PYTHON_EOL_JSON=""
UBUNTU_EOL_JSON=""

fetch_eol_data() {
  echo "Fetching EOL data from endoflife.date..."
  NODE_EOL_JSON=$(curl --disable --silent --fail "${EOL_API}/nodejs.json" 2>/dev/null || echo "[]")
  PYTHON_EOL_JSON=$(curl --disable --silent --fail "${EOL_API}/python.json" 2>/dev/null || echo "[]")
  UBUNTU_EOL_JSON=$(curl --disable --silent --fail "${EOL_API}/ubuntu.json" 2>/dev/null || echo "[]")
  echo "  Node.js cycles: $(echo "$NODE_EOL_JSON" | jq 'length')"
  echo "  Python cycles:  $(echo "$PYTHON_EOL_JSON" | jq 'length')"
  echo "  Ubuntu cycles:  $(echo "$UBUNTU_EOL_JSON" | jq 'length')"
}

# Returns 0 (true) if the given date is within EOL_WINDOW days from today or already past
is_eol_soon() {
  local eol_date="$1"
  [[ "$eol_date" == "false" ]] && return 1  # never EOL
  local eol_epoch today_epoch window_epoch
  eol_epoch=$(date -d "$eol_date" +%s 2>/dev/null) || return 1
  today_epoch=$(date -d "$TODAY" +%s)
  window_epoch=$(( today_epoch + EOL_WINDOW * 86400 ))
  [[ $eol_epoch -le $window_epoch ]]
}

# Returns the EOL date for a Node.js major version, or "false" if not found/not EOL
node_eol_date() {
  local major="$1"
  echo "$NODE_EOL_JSON" | jq -r --arg v "$major" \
    '.[] | select(.cycle == $v) | .eol' 2>/dev/null || echo "false"
}

# Returns the EOL date for a Python X.Y version, or "false" if not found/not EOL
python_eol_date() {
  local version="$1"
  # Normalise: "3.9.1" → "3.9", "3.9" → "3.9"
  local cycle
  cycle=$(echo "$version" | grep -oP '^\d+\.\d+')
  echo "$PYTHON_EOL_JSON" | jq -r --arg v "$cycle" \
    '.[] | select(.cycle == $v) | .eol' 2>/dev/null || echo "false"
}

# Returns the EOL date for an Ubuntu version string like "ubuntu-20.04", or "false"
ubuntu_eol_date() {
  local runner="$1"
  local cycle
  cycle=$(echo "$runner" | grep -oP '\d+\.\d+')
  [[ -z "$cycle" ]] && echo "false" && return
  echo "$UBUNTU_EOL_JSON" | jq -r --arg v "$cycle" \
    '.[] | select(.cycle == $v) | .eol' 2>/dev/null || echo "false"
}

# ── Action version cache ──────────────────────────────────────────────────────
# Avoid re-fetching the same action's latest release and node runtime repeatedly.

declare -A ACTION_LATEST_CACHE   # action_slug → latest_tag
declare -A ACTION_RUNTIME_CACHE  # action_slug@tag → node runtime string

# Returns the latest release tag for owner/action (e.g. "v4")
action_latest_tag() {
  local slug="$1"  # e.g. "actions/checkout"
  if [[ -v ACTION_LATEST_CACHE["$slug"] ]]; then
    echo "${ACTION_LATEST_CACHE[$slug]}"
    return
  fi
  local tag
  tag=$(api_get "${API}/repos/${slug}/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)
  # Fall back to tags list if no releases
  if [[ -z "$tag" ]]; then
    tag=$(api_get "${API}/repos/${slug}/tags?per_page=1" | jq -r '.[0].name // empty' 2>/dev/null)
  fi
  ACTION_LATEST_CACHE["$slug"]="$tag"
  echo "$tag"
}

# Returns the node runtime string from action.yml at a given ref (e.g. "node20", "node24")
action_node_runtime() {
  local slug="$1" ref="$2"
  local cache_key="${slug}@${ref}"
  if [[ -v ACTION_RUNTIME_CACHE["$cache_key"] ]]; then
    echo "${ACTION_RUNTIME_CACHE[$cache_key]}"
    return
  fi
  local runtime=""
  # Try action.yml, then action/action.yml (composite actions)
  for path in "action.yml" "action.yaml"; do
    runtime=$(api_get "${API}/repos/${slug}/contents/${path}?ref=${ref}" \
      | jq -r '.content // empty' | base64 -d 2>/dev/null \
      | grep -oP '(?<=using: ["\x27]?)node\d+' | head -1)
    [[ -n "$runtime" ]] && break
  done
  ACTION_RUNTIME_CACHE["$cache_key"]="$runtime"
  echo "$runtime"
}

# Node runtime deprecation: map action runtime strings to Node.js major versions
# and check against the endoflife.date data already fetched.
#   node12 → Node 12 (EOL 2022-04-30)
#   node16 → Node 16 (EOL 2023-09-11)
#   node20 → Node 20 (EOL 2026-04-30)
#   node24 → Node 24 (EOL 2028-04-30, current)
runtime_is_deprecated() {
  local runtime="$1"
  local major
  major=$(echo "$runtime" | grep -oP '\d+')
  [[ -z "$major" ]] && return 1
  local eol_date
  eol_date=$(node_eol_date "$major")
  is_eol_soon "$eol_date"
}

# ── Version comparison ────────────────────────────────────────────────────────

# Extract major version number from a tag like "v4", "v4.3.1", "4", "codeql-bundle-v2.25.3"
extract_major() {
  local tag="$1"
  echo "$tag" | grep -oP '(?<=[vV])\d+' | head -1
}

# Returns 0 if latest_tag represents a higher major version than current_tag
is_major_upgrade() {
  local current="$1" latest="$2"
  local cur_major lat_major
  cur_major=$(extract_major "$current")
  lat_major=$(extract_major "$latest")
  [[ -n "$cur_major" && -n "$lat_major" && "$lat_major" -gt "$cur_major" ]]
}

# Build the replacement tag: prefer the floating major alias (e.g. v6) when it
# exists as a real ref in the action's repo; fall back to the full release tag
# (e.g. v6.0.2) otherwise. Some actions only publish full semver tags without a
# floating alias — using a non-existent ref like @v6 causes workflow startup
# failures even though the release itself is valid.
replacement_tag() {
  local slug="$1" current_ref="$2" latest_tag="$3"
  local lat_major
  lat_major=$(extract_major "$latest_tag")
  [[ -z "$lat_major" ]] && echo "$latest_tag" && return

  local major_alias="v${lat_major}"

  # Verify the floating major alias exists as a ref in the action's repo.
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${slug}/git/ref/tags/${major_alias}" 2>/dev/null)

  if [[ "$http_code" == "200" ]]; then
    echo "$major_alias"
  else
    # No floating alias — use the full release tag for precision.
    echo "$latest_tag"
  fi
}

# ── Workflow file analysis ────────────────────────────────────────────────────

# Analyse a single workflow file's content. Prints sed-compatible substitution
# commands (one per line) for each outdated dependency found.
# Output format: TYPE|OLD|NEW|REASON
find_updates() {
  local content="$1"
  local updates=()

  # ── GitHub Actions versions ───────────────────────────────────────────────
  # Extract all unique "uses: owner/action@ref" references
  local actions_used
  actions_used=$(echo "$content" | grep -oP 'uses:\s*\K[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+@[^\s#]+' | sort -u)

  while IFS= read -r action_ref; do
    [[ -z "$action_ref" ]] && continue
    local slug ref
    slug=$(echo "$action_ref" | cut -d@ -f1)
    ref=$(echo "$action_ref" | cut -d@ -f2)

    # Skip SHA-pinned refs (40-char hex) — intentional pinning
    if echo "$ref" | grep -qP '^[0-9a-f]{40}$'; then
      continue
    fi

    local latest_tag
    latest_tag=$(action_latest_tag "$slug")
    [[ -z "$latest_tag" ]] && continue

    local needs_update=false reason=""

    # Check if current node runtime is deprecated
    local current_runtime
    current_runtime=$(action_node_runtime "$slug" "$ref")
    if [[ -n "$current_runtime" ]] && runtime_is_deprecated "$current_runtime"; then
      needs_update=true
      local latest_runtime
      latest_runtime=$(action_node_runtime "$slug" "$latest_tag")
      reason="node runtime ${current_runtime} deprecated"
      [[ -n "$latest_runtime" ]] && reason+=" (latest uses ${latest_runtime})"
    fi

    # Also flag if a newer major version exists (regardless of runtime)
    if ! $needs_update && is_major_upgrade "$ref" "$latest_tag"; then
      needs_update=true
      local new_ref
      new_ref=$(replacement_tag "$slug" "$ref" "$latest_tag")
      reason="newer major available (${ref} → ${new_ref})"
    fi

    if $needs_update; then
      local new_ref
      new_ref=$(replacement_tag "$slug" "$ref" "$latest_tag")
      [[ "$new_ref" == "$ref" ]] && continue  # already at latest major
      updates+=("action|${action_ref}|${slug}@${new_ref}|${reason}")
    fi
  done <<< "$actions_used"

  # ── Runner images ─────────────────────────────────────────────────────────
  # Match pinned ubuntu versions: ubuntu-20.04, ubuntu-22.04, etc.
  local runners_used
  runners_used=$(echo "$content" | grep -oP 'ubuntu-\d+\.\d+' | sort -u)

  while IFS= read -r runner; do
    [[ -z "$runner" ]] && continue
    local eol_date
    eol_date=$(ubuntu_eol_date "$runner")
    if is_eol_soon "$eol_date"; then
      # Suggest ubuntu-24.04 (current LTS) as replacement
      updates+=("runner|${runner}|ubuntu-24.04|Ubuntu ${runner#ubuntu-} EOL ${eol_date}")
    fi
  done <<< "$runners_used"

  # ── Node.js versions ──────────────────────────────────────────────────────
  # Match: node-version: "18", node-version: '18', node-version: 18
  local node_versions
  node_versions=$(echo "$content" | grep -oP "node-version:\s*['\"]?\K\d+" | sort -u)

  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    # Skip matrix references like ${{ matrix.node }}
    local eol_date
    eol_date=$(node_eol_date "$ver")
    if is_eol_soon "$eol_date"; then
      # Suggest Node 22 (current LTS)
      updates+=("node-version|${ver}|22|Node.js ${ver} EOL ${eol_date}")
    fi
  done <<< "$node_versions"

  # ── Python versions ───────────────────────────────────────────────────────
  local python_versions
  python_versions=$(echo "$content" | grep -oP "python-version:\s*['\"]?\K[\d.]+" | sort -u)

  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    local eol_date
    eol_date=$(python_eol_date "$ver")
    if is_eol_soon "$eol_date"; then
      # Suggest Python 3.12 (current stable LTS)
      updates+=("python-version|${ver}|3.12|Python ${ver} EOL ${eol_date}")
    fi
  done <<< "$python_versions"

  printf '%s\n' "${updates[@]}"
}

# Apply a list of updates (from find_updates) to a workflow file's content.
# Returns the modified content on stdout.
# ── Raw GitHub URL pin scanner ────────────────────────────────────────────────
# Finds patterns like:
#   raw.githubusercontent.com/<owner>/<repo>/v1.2.3/...
#   raw.githubusercontent.com/<owner>/<repo>/1.2.3/...
# and checks whether a newer release exists for that repo.

declare -A RAW_URL_LATEST_CACHE  # owner/repo → latest tag

raw_url_latest_tag() {
  local slug="$1"  # owner/repo
  if [[ -v RAW_URL_LATEST_CACHE["$slug"] ]]; then
    echo "${RAW_URL_LATEST_CACHE[$slug]}"
    return
  fi
  local tag
  tag=$(api_get "${API}/repos/${slug}/releases/latest" \
    | jq -r '.tag_name // empty' 2>/dev/null || echo "")
  RAW_URL_LATEST_CACHE["$slug"]="$tag"
  echo "$tag"
}

find_raw_url_updates() {
  local content="$1"
  local updates=()

  # Match: raw.githubusercontent.com/<owner>/<repo>/<tag>/<path>
  # Tag must look like a version: v1.2.3, v1.2, 1.2.3, 1.2
  local pattern='raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(v?[0-9]+\.[0-9]+(\.[0-9]+)?)/([^"'"'"' \t\n]+)'

  while IFS= read -r line; do
    local slug tag file_path
    slug=$(echo "$line"     | python3 -c "import re,sys; m=re.search(r'raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(v?[0-9]+\.[0-9]+(?:\.[0-9]+)?)/([^\"\047 \t\n]+)', sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null)
    tag=$(echo "$line"      | python3 -c "import re,sys; m=re.search(r'raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(v?[0-9]+\.[0-9]+(?:\.[0-9]+)?)/([^\"\047 \t\n]+)', sys.stdin.read()); print(m.group(2) if m else '')" 2>/dev/null)
    file_path=$(echo "$line"| python3 -c "import re,sys; m=re.search(r'raw\.githubusercontent\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(v?[0-9]+\.[0-9]+(?:\.[0-9]+)?)/([^\"\047 \t\n]+)', sys.stdin.read()); print(m.group(3) if m else '')" 2>/dev/null)

    [[ -z "$slug" || -z "$tag" ]] && continue

    local latest_tag
    latest_tag=$(raw_url_latest_tag "$slug")
    [[ -z "$latest_tag" ]] && continue

    # Normalise both to comparable form (strip leading v)
    local current_norm latest_norm
    current_norm="${tag#v}"
    latest_norm="${latest_tag#v}"

    [[ "$current_norm" == "$latest_norm" ]] && continue

    # Build old and new full URL fragments for replacement
    local old_fragment="raw.githubusercontent.com/${slug}/${tag}/${file_path}"
    local new_fragment="raw.githubusercontent.com/${slug}/${latest_tag}/${file_path}"

    updates+=("raw_url|${old_fragment}|${new_fragment}|${slug} ${tag} → ${latest_tag}")
  done < <(echo "$content" | grep -oE 'raw\.githubusercontent\.com/[A-Za-z0-9_./v-]+' | sort -u \
    || echo "$content" | grep 'raw.githubusercontent.com')

  printf '%s\n' "${updates[@]+"${updates[@]}"}"
}

# ── Devcontainer feature version scanner ──────────────────────────────────────
# Finds "version": "X.Y.Z" in devcontainer-feature.json files where the
# feature has a documentationURL pointing to a GitHub repo, and checks
# whether a newer release exists.

find_devcontainer_updates() {
  local content="$1" file_path="$2"
  local updates=()

  # Only process devcontainer-feature.json files
  [[ "$file_path" != *devcontainer-feature.json ]] && return

  local version doc_url slug
  version=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || echo "")
  doc_url=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin).get('documentationURL',''))" 2>/dev/null || echo "")

  [[ -z "$version" || -z "$doc_url" ]] && return

  # Extract owner/repo from documentationURL (must be a github.com URL)
  slug=$(echo "$doc_url" | python3 -c "
import re,sys
m = re.search(r'github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)', sys.stdin.read())
print(m.group(1) if m else '')
" 2>/dev/null)

  [[ -z "$slug" ]] && return

  local latest_tag
  latest_tag=$(raw_url_latest_tag "$slug")
  [[ -z "$latest_tag" ]] && return

  local current_norm latest_norm
  current_norm="${version#v}"
  latest_norm="${latest_tag#v}"

  [[ "$current_norm" == "$latest_norm" ]] && return

  # The version appears in two places in the JSON:
  #   "version": "X.Y.Z"  (feature metadata)
  #   "default": "X.Y.Z"  (option default)
  # We update both.
  updates+=("devcontainer_feature|${version}|${latest_norm}|${slug} ${version} → ${latest_norm}")

  printf '%s\n' "${updates[@]+"${updates[@]}"}"
}

apply_updates() {
  local content="$1"
  local updates="$2"

  while IFS='|' read -r type old new reason; do
    [[ -z "$type" ]] && continue
    case "$type" in
      raw_url)
        # old and new are full URL fragments — replace exactly
        local escaped_old escaped_new
        escaped_old=$(printf '%s' "$old" | sed 's/[[\.*^$()+?{|]/\\&/g')
        escaped_new=$(printf '%s' "$new" | sed 's/[[\.*^$()+?{|]/\\&/g')
        content=$(echo "$content" | sed "s|${escaped_old}|${escaped_new}|g")
        ;;
      devcontainer_feature)
        # Update "version": "X.Y.Z" and "default": "X.Y.Z" in the JSON
        content=$(echo "$content" \
          | sed "s/\"version\": \"${old}\"/\"version\": \"${new}\"/g" \
          | sed "s/\"default\": \"${old}\"/\"default\": \"${new}\"/g")
        ;;
      action)
        # Escape for sed: replace the exact action@ref string
        local old_esc new_esc
        old_esc=$(printf '%s' "$old" | sed 's/[[\.*^$()+?{|]/\\&/g')
        new_esc=$(printf '%s' "$new" | sed 's/[[\.*^$()+?{|]/\\&/g')
        content=$(echo "$content" | sed "s|${old_esc}|${new_esc}|g")
        ;;
      runner)
        content=$(echo "$content" | sed "s|${old}|${new}|g")
        ;;
      node-version)
        # Replace node-version: "OLD" / 'OLD' / OLD — be precise to avoid
        # replacing version numbers that appear in other contexts
        content=$(echo "$content" | sed -E \
          "s|(node-version:[[:space:]]*['\"]?)${old}(['\"]?)|\1${new}\2|g")
        ;;
      python-version)
        content=$(echo "$content" | sed -E \
          "s|(python-version:[[:space:]]*['\"]?)${old}(['\"]?)|\1${new}\2|g")
        ;;
    esac
  done <<< "$updates"

  echo "$content"
}

# ── Branch / PR helpers ───────────────────────────────────────────────────────

branch_exists() {
  local owner="$1" repo="$2" branch="$3"
  local code
  code=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    "${AUTH[@]}" "${API}/repos/${owner}/${repo}/git/ref/heads/${branch}")
  [[ "$code" == "200" ]]
}

open_pr_exists() {
  local owner="$1" repo="$2" branch="$3"
  local count
  count=$(api_get "${API}/repos/${owner}/${repo}/pulls?state=open&head=${owner}:${branch}&per_page=1" \
    | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]]
}

create_branch() {
  local owner="$1" repo="$2" branch="$3" sha="$4"
  local payload
  payload=$(jq -n --arg ref "refs/heads/${branch}" --arg sha "$sha" \
    '{ref: $ref, sha: $sha}')
  api_post "${API}/repos/${owner}/${repo}/git/refs" "$payload" > /dev/null
}

commit_file_to_branch() {
  local owner="$1" repo="$2" path="$3" branch="$4" message="$5" content_b64="$6" sha="$7"
  local payload
  payload=$(jq -n \
    --arg m "$message" --arg c "$content_b64" --arg s "$sha" --arg b "$branch" \
    '{message: $m, content: $c, sha: $s, branch: $b}')
  api_put "${API}/repos/${owner}/${repo}/contents/${path}" "$payload" > /dev/null
}

create_pr() {
  local owner="$1" repo="$2" branch="$3" base="$4" title="$5" body="$6"
  local payload
  payload=$(jq -n \
    --arg title "$title" --arg body "$body" \
    --arg head "$branch" --arg base "$base" \
    '{title: $title, body: $body, head: $head, base: $base}')
  api_post "${API}/repos/${owner}/${repo}/pulls" "$payload" | jq -r '.html_url // empty'
}

# ── Per-repo processor ────────────────────────────────────────────────────────

process_repo() {
  local owner="$1" repo="$2"
  echo "  ${owner}/${repo}"

  # Get default branch and its HEAD SHA
  local repo_info
  repo_info=$(api_get "${API}/repos/${owner}/${repo}")
  local default_branch head_sha
  default_branch=$(echo "$repo_info" | jq -r '.default_branch // "main"')
  head_sha=$(api_get "${API}/repos/${owner}/${repo}/git/ref/heads/${default_branch}" \
    | jq -r '.object.sha // empty')
  [[ -z "$head_sha" ]] && echo "    ⚠ Could not get HEAD SHA — skipping" && return

  # List workflow files
  local wf_list
  wf_list=$(api_get "${API}/repos/${owner}/${repo}/contents/.github/workflows" 2>/dev/null)
  local wf_count
  wf_count=$(echo "$wf_list" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [[ "$wf_count" -eq 0 ]] && echo "    no workflows" && return

  (( repos_scanned++ )) || true

  # Collect all updates across all scanned files in this repo
  declare -A file_updates   # path → pipe-separated update lines
  declare -A file_content   # path → original content
  declare -A file_sha       # path → blob SHA

  # ── Workflow files (.github/workflows/*.yml) ──────────────────────────────
  local wf_paths
  wf_paths=$(echo "$wf_list" | jq -r '.[] | select(.name | endswith(".yml") or endswith(".yaml")) | .path')

  while IFS= read -r wf_path; do
    [[ -z "$wf_path" ]] && continue
    local file_info
    file_info=$(api_get "${API}/repos/${owner}/${repo}/contents/${wf_path}")
    local content blob_sha
    content=$(echo "$file_info" | jq -r '.content // empty' | base64 -d 2>/dev/null)
    blob_sha=$(echo "$file_info" | jq -r '.sha // empty')
    [[ -z "$content" ]] && continue

    local updates=""
    local wf_updates raw_updates
    wf_updates=$(find_updates "$content")
    raw_updates=$(find_raw_url_updates "$content")
    [[ -n "$wf_updates"  ]] && updates+="${wf_updates}"$'\n'
    [[ -n "$raw_updates" ]] && updates+="${raw_updates}"$'\n'
    updates="${updates%$'\n'}"  # trim trailing newline

    if [[ -n "$updates" ]]; then
      file_updates["$wf_path"]="$updates"
      file_content["$wf_path"]="$content"
      file_sha["$wf_path"]="$blob_sha"
    fi
  done <<< "$wf_paths"

  # ── Devcontainer files (.devcontainer/**) ─────────────────────────────────
  # Scan recursively for devcontainer-feature.json and devcontainer.json files
  # that may contain raw URL pins or versioned feature declarations.
  local dc_paths
  dc_paths=$(api_get "${API}/repos/${owner}/${repo}/git/trees/${head_sha}?recursive=1" 2>/dev/null \
    | jq -r '.tree[] | select(.type=="blob") | select(
        (.path | startswith(".devcontainer/")) and
        (.path | (endswith("devcontainer-feature.json") or endswith("devcontainer.json")))
      ) | .path' 2>/dev/null || echo "")

  while IFS= read -r dc_path; do
    [[ -z "$dc_path" ]] && continue
    local file_info
    file_info=$(api_get "${API}/repos/${owner}/${repo}/contents/${dc_path}")
    local content blob_sha
    content=$(echo "$file_info" | jq -r '.content // empty' | base64 -d 2>/dev/null)
    blob_sha=$(echo "$file_info" | jq -r '.sha // empty')
    [[ -z "$content" ]] && continue

    local updates=""
    local raw_updates dc_updates
    raw_updates=$(find_raw_url_updates "$content")
    dc_updates=$(find_devcontainer_updates "$content" "$dc_path")
    [[ -n "$raw_updates" ]] && updates+="${raw_updates}"$'\n'
    [[ -n "$dc_updates"  ]] && updates+="${dc_updates}"$'\n'
    updates="${updates%$'\n'}"

    if [[ -n "$updates" ]]; then
      file_updates["$dc_path"]="$updates"
      file_content["$dc_path"]="$content"
      file_sha["$dc_path"]="$blob_sha"
    fi
  done <<< "$dc_paths"

  if [[ ${#file_updates[@]} -eq 0 ]]; then
    echo "    ✓ up to date"
    return
  fi

  # Summarise what was found
  local total_changes=0
  for wf_path in "${!file_updates[@]}"; do
    local count
    count=$(echo "${file_updates[$wf_path]}" | grep -c "." || true)
    echo "    ${wf_path}: ${count} update(s)"
    while IFS='|' read -r type old new reason; do
      echo "      ${type}: ${old} → ${new}  (${reason})"
    done <<< "${file_updates[$wf_path]}"
    (( total_changes += count )) || true
  done

  (( repos_updated++ )) || true

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] would open PR on branch ${PR_BRANCH}"
    return
  fi

  # Check if PR already exists for this branch
  if open_pr_exists "$owner" "$repo" "$PR_BRANCH"; then
    echo "    ↩ PR already open for ${PR_BRANCH} — skipping"
    (( prs_skipped++ )) || true
    return
  fi

  # Create branch from HEAD
  if branch_exists "$owner" "$repo" "$PR_BRANCH"; then
    echo "    ↩ branch ${PR_BRANCH} already exists — skipping"
    (( prs_skipped++ )) || true
    return
  fi

  create_branch "$owner" "$repo" "$PR_BRANCH" "$head_sha"

  # Commit each updated file to the branch
  local pr_body_files=""
  for wf_path in "${!file_updates[@]}"; do
    local new_content new_b64
    new_content=$(apply_updates "${file_content[$wf_path]}" "${file_updates[$wf_path]}")
    new_b64=$(printf '%s' "$new_content" | base64 -w0)
    commit_file_to_branch \
      "$owner" "$repo" "$wf_path" "$PR_BRANCH" \
      "chore(deps): update workflow dependencies in ${wf_path##*/}" \
      "$new_b64" "${file_sha[$wf_path]}"

    pr_body_files+="**\`${wf_path}\`**"$'\n'
    while IFS='|' read -r type old new reason; do
      pr_body_files+="- \`${old}\` → \`${new}\` — ${reason}"$'\n'
    done <<< "${file_updates[$wf_path]}"
    pr_body_files+=$'\n'
  done

  # Build PR body
  local pr_body
  pr_body=$(cat <<EOF
Automated dependency update for GitHub Actions workflow files.

${pr_body_files}
---
*Generated by [update-infra-deps.yml](/.github/workflows/update-infra-deps.yml) on ${TODAY}.*
*EOL data sourced from [endoflife.date](https://endoflife.date).*
EOF
)

  local pr_title="chore(deps): update workflow infrastructure dependencies"
  [[ "$total_changes" -eq 1 ]] && pr_title="chore(deps): update 1 workflow dependency"
  [[ "$total_changes" -gt 1 ]] && pr_title="chore(deps): update ${total_changes} workflow dependencies"

  local pr_url
  pr_url=$(create_pr "$owner" "$repo" "$PR_BRANCH" "$default_branch" "$pr_title" "$pr_body")

  if [[ -n "$pr_url" ]]; then
    echo "    ✅ PR opened: ${pr_url}"
    (( prs_opened++ )) || true
  else
    echo "    ❌ Failed to open PR"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════════"
echo "Infrastructure dependency scanner"
echo "Date:       ${TODAY}"
echo "EOL window: ${EOL_WINDOW} days"
echo "Dry run:    ${DRY_RUN}"
echo "Owners:     ${SCAN_OWNERS}"
echo "════════════════════════════════════════════════════════"
echo ""

# Validate token
remaining=$(api_get "${API}/rate_limit" | jq -r '.resources.core.remaining // empty')
[[ -z "$remaining" ]] && { echo "ERROR: GH_TOKEN invalid or missing permissions."; exit 1; }
echo "API requests remaining: ${remaining}"
echo ""

fetch_eol_data
echo ""

for owner in $SCAN_OWNERS; do
  echo "════════════════════════════════════════"
  echo "Scanning ${owner}..."
  echo ""

  # Paginate repos
  local_page=1
  while true; do
    repos=$(api_get "${API}/orgs/${owner}/repos?per_page=100&page=${local_page}&sort=pushed")
    repo_count=$(echo "$repos" | jq 'if type=="array" then length else 0 end')
    [[ "$repo_count" -eq 0 ]] && break

    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      archived=$(api_get "${API}/repos/${owner}/${repo}" | jq -r '.archived')
      [[ "$archived" == "true" ]] && continue
      process_repo "$owner" "$repo"
    done < <(echo "$repos" | jq -r '.[].name')

    [[ "$repo_count" -lt 100 ]] && break
    (( local_page++ )) || true
  done
  echo ""
done

echo "════════════════════════════════════════════════════════"
echo "Summary"
echo "  Repos scanned (with workflows): ${repos_scanned}"
echo "  Repos with outdated deps:       ${repos_updated}"
echo "  PRs opened:                     ${prs_opened}"
echo "  PRs skipped (already open):     ${prs_skipped}"
echo "════════════════════════════════════════════════════════"
