#!/usr/bin/env bash
#
# Validates a Interested-Deving-1896/<repo> URL, mirrors it into OSP
# immediately, and creates it in OOC so the full chain is registered.
#
# "Registered for ongoing sync" means the repo exists in OSP — mirror-to-osp.sh
# discovers repos dynamically by cross-checking OSP against the upstream, so
# no config file needs updating. The hourly mirror-to-osp.yml run will keep it
# in sync from this point forward. setup-osp-mirrors.sh (runs at :45) will
# inject the OSP→OOC workflow into the new OSP repo automatically.
#
# Requires: GH_TOKEN (repo + admin:org + workflow scopes),
#           REPO_URL, UPSTREAM_OWNER, OSP_ORG, OOC_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_URL:?REPO_URL is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

# ── helpers ────────────────────────────────────────────────────────────────

api_get() {
  curl --disable --silent \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "$@"
}

api_post() {
  local url="$1"; shift
  curl --disable --silent -w "\n%{http_code}" \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

sanitize() {
  sed "s/${GH_TOKEN}/***TOKEN***/g"
}

# ── 1. Parse and validate the URL ─────────────────────────────────────────

# Strip trailing .git and whitespace
clean_url="${REPO_URL%.git}"
clean_url="${clean_url%/}"
clean_url="${clean_url#"${clean_url%%[![:space:]]*}"}"

# Extract owner/repo from https://github.com/<owner>/<repo>
if [[ "$clean_url" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
  url_owner="${BASH_REMATCH[1]}"
  repo_name="${BASH_REMATCH[2]}"
else
  echo "ERROR: URL must be in the form https://github.com/${UPSTREAM_OWNER}/<repo>"
  echo "  Got: ${REPO_URL}"
  exit 1
fi

if [[ "$url_owner" != "$UPSTREAM_OWNER" ]]; then
  echo "ERROR: URL owner '${url_owner}' is not '${UPSTREAM_OWNER}'."
  echo "  Only repos from ${UPSTREAM_OWNER} can be added via this workflow."
  exit 1
fi

echo "Repo:  ${UPSTREAM_OWNER}/${repo_name}"
echo ""

# ── 2. Validate token ─────────────────────────────────────────────────────

echo "Validating token..."
if ! api_get "${API}/user" | jq -e '.login' >/dev/null 2>&1; then
  echo "ERROR: GH_TOKEN is invalid or lacks required permissions."
  exit 1
fi
echo "Token OK."
echo ""

# ── 3. Confirm upstream repo exists and is accessible ─────────────────────

echo "Checking upstream repo..."
upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo_name}")
upstream_exists=$(echo "$upstream_info" | jq -r '.name // empty')

if [[ -z "$upstream_exists" ]]; then
  echo "ERROR: ${UPSTREAM_OWNER}/${repo_name} not found or not accessible."
  exit 1
fi

upstream_private=$(echo "$upstream_info" | jq -r '.private')
upstream_desc=$(echo "$upstream_info" | jq -r '.description // ""')
echo "  Found: ${UPSTREAM_OWNER}/${repo_name} (private: ${upstream_private})"
echo ""

# ── 4. Create repo in OSP if it doesn't exist ─────────────────────────────

echo "Checking ${OSP_ORG}/${repo_name}..."
osp_exists=$(api_get "${API}/repos/${OSP_ORG}/${repo_name}" | jq -r '.name // empty')

if [[ -n "$osp_exists" ]]; then
  echo "  Already exists in ${OSP_ORG} — will overwrite via mirror push."
else
  echo "  Creating ${OSP_ORG}/${repo_name}..."
  payload=$(jq -n \
    --arg name "$repo_name" \
    --arg desc "Mirrored from ${UPSTREAM_OWNER}/${repo_name}" \
    --argjson private "$upstream_private" \
    '{name: $name, description: $desc, private: $private,
      has_issues: true, has_projects: true, has_wiki: true}')
  response=$(api_post "${API}/orgs/${OSP_ORG}/repos" -d "$payload")
  http_code=$(echo "$response" | tail -1)
  if [[ "$http_code" != "201" ]]; then
    echo "  ERROR: Failed to create repo (HTTP $http_code)"
    echo "$response" | sed '$d'
    exit 1
  fi
  echo "  Created (HTTP $http_code). Waiting for GitHub to initialise..."
  sleep 5
fi
echo ""

# ── 5. Create repo in OOC if it doesn't exist ─────────────────────────────

echo "Checking ${OOC_ORG}/${repo_name}..."
ooc_exists=$(api_get "${API}/repos/${OOC_ORG}/${repo_name}" | jq -r '.name // empty')

if [[ -n "$ooc_exists" ]]; then
  echo "  Already exists in ${OOC_ORG}."
else
  echo "  Creating ${OOC_ORG}/${repo_name}..."
  payload=$(jq -n \
    --arg name "$repo_name" \
    --arg desc "Mirrored from ${OSP_ORG}/${repo_name}" \
    --argjson private "$upstream_private" \
    '{name: $name, description: $desc, private: $private,
      has_issues: false, has_projects: false, has_wiki: false}')
  response=$(api_post "${API}/orgs/${OOC_ORG}/repos" -d "$payload")
  http_code=$(echo "$response" | tail -1)
  if [[ "$http_code" != "201" ]]; then
    echo "  ERROR: Failed to create repo in OOC (HTTP $http_code)"
    echo "$response" | sed '$d'
    exit 1
  fi
  echo "  Created (HTTP $http_code)."
fi
echo ""

# ── 6. Bare clone upstream and push --mirror into OSP ─────────────────────

echo "Mirroring ${UPSTREAM_OWNER}/${repo_name} → ${OSP_ORG}/${repo_name}..."

tmpdir=$(mktemp -d)
clonedir="${tmpdir}/${repo_name}.git"
trap 'rm -rf "$tmpdir"' EXIT

upstream_url="https://x-access-token:${GH_TOKEN}@github.com/${UPSTREAM_OWNER}/${repo_name}.git"
osp_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${repo_name}.git"

if ! git clone --bare "$upstream_url" "$clonedir" 2>&1 | sanitize; then
  echo "ERROR: Could not clone ${UPSTREAM_OWNER}/${repo_name}"
  exit 1
fi

cd "$clonedir"

attempt=0
push_ok=false
while (( attempt < 3 )); do
  push_output=$(git push --mirror "$osp_url" 2>&1) || true
  sanitized=$(echo "$push_output" | sanitize)

  if ! echo "$push_output" | grep -q "remote rejected"; then
    echo "$sanitized"
    push_ok=true
    break
  fi

  if echo "$push_output" | grep -q "without \`workflow\` scope"; then
    echo "$sanitized"
    echo "ERROR: GH_TOKEN needs the 'workflow' scope to push repos containing .github/workflows/"
    break
  fi

  (( attempt++ ))
  echo "$sanitized"
  (( attempt < 3 )) && { echo "  push attempt ${attempt} failed, retrying in 5s..."; sleep 5; }
done

cd /

if ! $push_ok; then
  echo "ERROR: Mirror push to ${OSP_ORG}/${repo_name} failed."
  exit 1
fi

echo ""
echo "========================================================"
echo "  Done: ${UPSTREAM_OWNER}/${repo_name}"
echo ""
echo "  Mirrored into:  ${OSP_ORG}/${repo_name}"
echo "  Registered in:  ${OOC_ORG}/${repo_name} (created, awaiting first push)"
echo ""
echo "  Ongoing sync:"
echo "    :00  mirror-to-osp.yml pushes upstream → OSP (hourly)"
echo "    :45  setup-osp-mirrors.sh injects OSP→OOC workflow into OSP repo"
echo "    :15  mirror-osp-to-ooc.yaml pushes OSP → OOC (once injected)"
echo "========================================================"
exit 0
