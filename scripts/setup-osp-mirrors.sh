#!/usr/bin/env bash
#
# For every repo present on both UPSTREAM_OWNER and OSP_ORG, ensures:
#   1. mirror-osp-to-ooc.yaml is present and active on the OSP repo
#   2. mirror.yaml is disabled on the OSP repo (OSP is not the push source)
#   3. MIRROR_TOKEN secret is set on the OSP repo
#   4. All mirror workflows are disabled on the OOC repo (terminal destination)
#
# Requires: GH_TOKEN (repo + workflow + admin:org scopes), UPSTREAM_OWNER,
#           OSP_ORG, OOC_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"
: "${OOC_ORG:?OOC_ORG is required}"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

# Repos the script must never touch (have custom mirror setups)
EXCLUDED_REPOS=(
  "fork-sync-all"
  "org-mirror"
)

is_excluded() {
  local repo="$1"
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$excluded" ]] && return 0
  done
  return 1
}

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

# ── Encrypt a secret value using the repo's public key ───────────────────────
set_secret() {
  local repo="$1" secret_name="$2" secret_value="$3"

  # Use Python end-to-end: fetch key, encrypt, PUT — avoids shell base64/jq issues
  python3 - "$GH_TOKEN" "$repo" "$secret_name" "$secret_value" <<'PYEOF'
import sys, base64, json, urllib.request, urllib.error
from nacl.public import PublicKey, SealedBox

token, repo, secret_name, secret_value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
headers = {"Authorization": f"token {token}", "Accept": "application/vnd.github+json"}
api = "https://api.github.com"

# Fetch public key
req = urllib.request.Request(f"{api}/repos/{repo}/actions/secrets/public-key", headers=headers)
with urllib.request.urlopen(req) as r:
    pk = json.loads(r.read())

key_id = pk["key_id"]
pub_key_bytes = base64.b64decode(pk["key"])
box = SealedBox(PublicKey(pub_key_bytes))
encrypted_b64 = base64.b64encode(box.encrypt(secret_value.encode())).decode()

payload = json.dumps({"encrypted_value": encrypted_b64, "key_id": key_id}).encode()
req2 = urllib.request.Request(
    f"{api}/repos/{repo}/actions/secrets/{secret_name}",
    data=payload, method="PUT",
    headers={**headers, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req2) as r:
        print(f"    secret {secret_name}: set (HTTP {r.status})")
except urllib.error.HTTPError as e:
    print(f"    secret {secret_name}: FAILED (HTTP {e.code}): {e.read().decode()[:100]}")
    sys.exit(1)
PYEOF
}

# ── Workflow file content generators ─────────────────────────────────────────
mirror_osp_to_ooc_content() {
  local repo="$1"
  cat <<YAML
name: Mirror to OpenOS-Project-Ecosystem-OOC

# Sync chain:
#   ${UPSTREAM_OWNER}  ->(upstream mirror.yaml)->  ${OSP_ORG}
#   ${OSP_ORG}  ->(this file)->  ${OOC_ORG}

on:
  push:
    branches: ["**"]
    tags: ["**"]
  schedule:
    # Runs 15 minutes after the upstream->OSP sync to allow OSP to settle
    - cron: "15 * * * *"
  workflow_dispatch:

jobs:
  mirror:
    runs-on: ubuntu-latest
    # Only run when executing in the OSP repo — no-op if mirrored elsewhere
    if: github.repository == '${OSP_ORG}/${repo}'
    steps:
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Fetch all branches and tags
        run: git fetch --all --tags --prune

      - name: Push mirror to ${OOC_ORG}
        env:
          MIRROR_TOKEN: \${{ secrets.MIRROR_TOKEN }}
        run: |
          git config --global credential.helper store
          printf 'https://x-access-token:%s@github.com\\n' "\$MIRROR_TOKEN" \\
            > ~/.git-credentials

          git remote add mirror \\
            "https://github.com/${OOC_ORG}/${repo}.git"

          git push mirror --all --force
          git push mirror --tags --force

          rm -f ~/.git-credentials
YAML
}

# ── Per-repo setup ────────────────────────────────────────────────────────────
setup_repo() {
  local repo="$1" default_branch="$2"
  local osp_repo="${OSP_ORG}/${repo}"
  local ooc_repo="${OOC_ORG}/${repo}"
  local changed=false

  # ── 1. Ensure mirror-osp-to-ooc.yaml is present and correct on OSP ────────
  local wf_path=".github/workflows/mirror-osp-to-ooc.yaml"
  local existing_sha desired_content current_content

  desired_content=$(mirror_osp_to_ooc_content "$repo")

  existing_sha=$(api_get \
    "${API}/repos/${osp_repo}/contents/${wf_path}?ref=${default_branch}" | \
    jq -r '.sha // empty')

  if [[ -n "$existing_sha" ]]; then
    current_content=$(api_get \
      "${API}/repos/${osp_repo}/contents/${wf_path}?ref=${default_branch}" | \
      jq -r '.content' | base64 -d 2>/dev/null)
    if [[ "$current_content" == "$desired_content" ]]; then
      echo "    mirror-osp-to-ooc.yaml: up to date"
    else
      # Update
      local encoded payload http_code
      encoded=$(echo "$desired_content" | base64 -w 0)
      payload=$(jq -n \
        --arg msg "ci: update mirror-osp-to-ooc.yaml [auto]" \
        --arg content "$encoded" \
        --arg sha "$existing_sha" \
        --arg branch "$default_branch" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}')
      http_code=$(api_put \
        "${API}/repos/${osp_repo}/contents/${wf_path}" -d "$payload")
      echo "    mirror-osp-to-ooc.yaml: updated (HTTP $http_code)"
      changed=true
    fi
  else
    # Create
    local encoded payload http_code
    encoded=$(echo "$desired_content" | base64 -w 0)
    payload=$(jq -n \
      --arg msg "ci: add mirror-osp-to-ooc.yaml [auto]" \
      --arg content "$encoded" \
      --arg branch "$default_branch" \
      '{message: $msg, content: $content, branch: $branch}')
    http_code=$(api_put \
      "${API}/repos/${osp_repo}/contents/${wf_path}" -d "$payload")
    echo "    mirror-osp-to-ooc.yaml: created (HTTP $http_code)"
    changed=true
  fi

  # ── 2. Disable mirror.yaml on OSP if active ───────────────────────────────
  local wf_id state
  wf_id=$(api_get "${API}/repos/${osp_repo}/actions/workflows" | \
    jq -r '.workflows[] | select(.path == ".github/workflows/mirror.yaml") | .id')
  if [[ -n "$wf_id" && "$wf_id" != "null" ]]; then
    state=$(api_get "${API}/repos/${osp_repo}/actions/workflows/${wf_id}" | \
      jq -r '.state')
    if [[ "$state" == "active" ]]; then
      local http_code
      http_code=$(api_put \
        "${API}/repos/${osp_repo}/actions/workflows/${wf_id}/disable")
      echo "    mirror.yaml on OSP: disabled (HTTP $http_code)"
      changed=true
    else
      echo "    mirror.yaml on OSP: already disabled"
    fi
  fi

  # ── 3. Set MIRROR_TOKEN secret on OSP ─────────────────────────────────────
  # Always refresh to ensure it matches the current token
  set_secret "$osp_repo" "MIRROR_TOKEN" "$GH_TOKEN"

  # ── 4. Disable all mirror workflows on OOC ────────────────────────────────
  api_get "${API}/repos/${ooc_repo}/actions/workflows" | \
    jq -r '.workflows[] | select((.path | contains("mirror")) and .state == "active") | .id' | \
  while read -r wf_id; do
    local http_code
    http_code=$(api_put \
      "${API}/repos/${ooc_repo}/actions/workflows/${wf_id}/disable")
    echo "    mirror workflow on OOC (id=$wf_id): disabled (HTTP $http_code)"
    changed=true
  done

  $changed && echo "    status: updated" || echo "    status: no changes needed"
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Fetching repos present on both ${UPSTREAM_OWNER} and ${OSP_ORG}..."

# Get all OSP repos
mapfile -t osp_repos < <(
  page=1
  while true; do
    result=$(api_get "${API}/orgs/${OSP_ORG}/repos?type=all&per_page=100&page=${page}")
    count=$(echo "$result" | jq 'length')
    [[ "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
)

echo "Found ${#osp_repos[@]} repos on ${OSP_ORG}."
echo ""

processed=0
skipped=0

for repo in "${osp_repos[@]}"; do
  [[ -z "$repo" ]] && continue

  if is_excluded "$repo"; then
    (( skipped++ )) || true
    continue
  fi

  # Check repo exists on upstream
  upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}")
  upstream_exists=$(echo "$upstream_info" | jq -r '.name // empty')
  if [[ -z "$upstream_exists" ]]; then
    # Not an upstream repo — skip (may be OSP-native)
    (( skipped++ )) || true
    continue
  fi

  default_branch=$(echo "$upstream_info" | jq -r '.default_branch // "main"')

  echo "Setting up mirrors for: ${repo} (branch: ${default_branch})"
  setup_repo "$repo" "$default_branch"
  (( processed++ )) || true
  echo ""
done

echo "========================================"
echo "  Mirror setup complete"
echo "  Repos processed: ${processed}"
echo "  Repos skipped:   ${skipped}"
echo "========================================"
exit 0
