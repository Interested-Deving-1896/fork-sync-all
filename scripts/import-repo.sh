#!/usr/bin/env bash
#
# Platform-agnostic repo importer.
#
# Clones any public or authenticated git URL and creates the repo in
# Interested-Deving-1896. Optionally pushes through the OSP→OOC mirror
# chain and/or registers the source for ongoing scheduled re-sync.
#
# Supported source platforms (auto-detected from URL):
#   github.com, gitlab.com, bitbucket.org, codeberg.org,
#   gitea.*, sourcehut.org, any other git-compatible host
#
# Required env vars:
#   GH_TOKEN       — GitHub PAT (repo + admin:org + workflow scopes)
#   REPO_URL       — source git URL (https or ssh)
#   GITHUB_OWNER   — target GitHub org (Interested-Deving-1896)
#
# Optional env vars:
#   REPO_NAME          — override repo name in GITHUB_OWNER (default: source name)
#   MIRROR_TO_OSP_OOC  — "true" to push through OSP→OOC chain
#   ONGOING_SYNC       — "true" to register in registered-imports.json
#   OSP_ORG            — OpenOS-Project-OSP
#   OOC_ORG            — OpenOS-Project-Ecosystem-OOC
#   GITLAB_TOKEN       — GitLab PAT (for private GitLab sources)
#   BITBUCKET_TOKEN    — Bitbucket app password (for private Bitbucket sources)
#   GITEA_TOKEN        — Gitea PAT (for private Gitea sources)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_URL:?REPO_URL is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

OSP_ORG="${OSP_ORG:-OpenOS-Project-OSP}"
OOC_ORG="${OOC_ORG:-OpenOS-Project-Ecosystem-OOC}"
MIRROR_TO_OSP_OOC="${MIRROR_TO_OSP_OOC:-false}"
ONGOING_SYNC="${ONGOING_SYNC:-false}"

GH_API="https://api.github.com"

info()  { echo "[import-repo] $*"; }
warn()  { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; exit 1; }

sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

gh_api_get() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

gh_api_post() {
  local url="$1"; shift
  curl -sf -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

# ── 1. Parse source URL ───────────────────────────────────────────────────────

# Normalise: strip trailing .git and whitespace
clean_url="${REPO_URL%.git}"
clean_url="${clean_url%/}"
clean_url="$(echo "$clean_url" | tr -d '[:space:]')"

# Detect platform from URL
platform="generic"
case "$clean_url" in
  *github.com*)    platform="github" ;;
  *gitlab.com*)    platform="gitlab" ;;
  *bitbucket.org*) platform="bitbucket" ;;
  *codeberg.org*)  platform="codeberg" ;;
  *sourcehut.org*|*sr.ht*) platform="sourcehut" ;;
  *gitea.*)        platform="gitea" ;;
esac

# Extract repo name from URL (last path component)
source_name="${clean_url##*/}"
source_name="${source_name%.git}"

# Apply optional rename
target_name="${REPO_NAME:-$source_name}"
# Sanitise: GitHub repo names allow alphanumeric, hyphens, underscores, dots
target_name="$(echo "$target_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"

info "Source URL  : ${clean_url}"
info "Platform    : ${platform}"
info "Source name : ${source_name}"
info "Target name : ${target_name}"
info "Mirror OSP/OOC : ${MIRROR_TO_OSP_OOC}"
info "Ongoing sync   : ${ONGOING_SYNC}"
echo ""

# ── 2. Pre-flight token check ────────────────────────────────────────────────
# Detect early whether a required token is missing and print the exact
# command to fix it — before attempting the clone and failing mid-way.

REPO_SLUG="Interested-Deving-1896/fork-sync-all"

token_missing_hint() {
  local secret_name="$1" platform_label="$2"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Missing token for ${platform_label} source"
  echo ""
  echo "  Run this command in your terminal, then paste the"
  echo "  token when prompted (input is hidden — never logged):"
  echo ""
  echo "    gh secret set ${secret_name} --repo ${REPO_SLUG}"
  echo ""
  echo "  Then re-run this workflow."
  echo "════════════════════════════════════════════════════════"
  echo ""
}

case "$platform" in
  gitlab)
    if [ -z "${GITLAB_TOKEN:-}" ]; then
      if echo "$clean_url" | grep -q "gitlab.com"; then
        info "No GITLAB_SYNC_TOKEN set — will attempt unauthenticated clone."
        info "If the repo is private this will fail. To fix:"
        token_missing_hint "GITLAB_SYNC_TOKEN" "GitLab"
        info "Continuing with unauthenticated attempt..."
      fi
    fi
    ;;
  bitbucket)
    if [ -z "${BITBUCKET_TOKEN:-}" ]; then
      info "No BITBUCKET_TOKEN set — will attempt unauthenticated clone."
      info "If the repo is private this will fail. To fix:"
      token_missing_hint "BITBUCKET_TOKEN" "Bitbucket"
      info "Continuing with unauthenticated attempt..."
    fi
    ;;
  gitea)
    if [ -z "${GITEA_TOKEN:-}" ]; then
      info "No GITEA_TOKEN set — will attempt unauthenticated clone."
      info "If the repo is private this will fail. To fix:"
      token_missing_hint "GITEA_TOKEN" "Gitea"
      info "Continuing with unauthenticated attempt..."
    fi
    ;;
  codeberg)
    if [ -z "${GITEA_TOKEN:-}" ]; then
      info "No GITEA_TOKEN set — Codeberg uses the same token as Gitea."
      info "If the repo is private this will fail. To fix:"
      token_missing_hint "GITEA_TOKEN" "Codeberg/Gitea"
      info "Continuing with unauthenticated attempt..."
    fi
    ;;
  sourcehut)
    info "Sourcehut repos are always public — no token needed."
    ;;
esac

# ── 3. Build authenticated clone URL ─────────────────────────────────────────

clone_url="$clean_url"

case "$platform" in
  github)
    clone_url="${clean_url/https:\/\//https://x-access-token:${GH_TOKEN}@}.git"
    ;;
  gitlab)
    if [ -n "${GITLAB_TOKEN:-}" ]; then
      clone_url="${clean_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}.git"
    else
      clone_url="${clean_url}.git"
      info "No GITLAB_TOKEN set — attempting unauthenticated clone (public repos only)"
    fi
    ;;
  bitbucket)
    if [ -n "${BITBUCKET_TOKEN:-}" ]; then
      # Bitbucket: https://<user>:<app-password>@bitbucket.org/...
      clone_url="${clean_url/https:\/\/bitbucket.org\//https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/}.git"
    else
      clone_url="${clean_url}.git"
      info "No BITBUCKET_TOKEN set — attempting unauthenticated clone (public repos only)"
    fi
    ;;
  gitea)
    if [ -n "${GITEA_TOKEN:-}" ]; then
      clone_url="${clean_url/https:\/\//https://x-access-token:${GITEA_TOKEN}@}.git"
    else
      clone_url="${clean_url}.git"
    fi
    ;;
  *)
    clone_url="${clean_url}.git"
    ;;
esac

# ── 3. Validate GitHub token ──────────────────────────────────────────────────

info "Validating GitHub token..."
if ! gh_api_get "${GH_API}/user" | grep -q '"login"'; then
  error "GH_TOKEN is invalid or lacks required permissions."
fi
info "Token OK."
echo ""

# ── 4. Create repo in Interested-Deving-1896 if missing ──────────────────────

info "Checking ${GITHUB_OWNER}/${target_name}..."
existing=$(gh_api_get "${GH_API}/repos/${GITHUB_OWNER}/${target_name}" 2>/dev/null \
  | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//' || echo "")

if [ -n "$existing" ]; then
  info "  Already exists — will overwrite via push."
else
  info "  Creating ${GITHUB_OWNER}/${target_name}..."
  payload=$(printf '{"name":"%s","description":"Imported from %s","private":false,"has_issues":true,"has_projects":true,"has_wiki":true}' \
    "$target_name" "$clean_url")
  response=$(gh_api_post "${GH_API}/orgs/${GITHUB_OWNER}/repos" -d "$payload")
  http_code=$(echo "$response" | tail -1)
  if [ "$http_code" != "201" ]; then
    error "Failed to create ${GITHUB_OWNER}/${target_name} (HTTP ${http_code}): $(echo "$response" | sed '$d')"
  fi
  info "  Created. Waiting for GitHub to initialise..."
  sleep 5
fi
echo ""

# ── 5. Bare clone from source and push to Interested-Deving-1896 ─────────────

info "Cloning ${clean_url} ..."
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if ! git clone --mirror "$clone_url" "$work_dir/repo.git" 2>&1 | sanitize; then
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Clone failed for: ${clean_url}"
  echo ""
  case "$platform" in
    gitlab)
      echo "  If this is a private GitLab repo, set the token:"
      echo "    gh secret set GITLAB_SYNC_TOKEN --repo ${REPO_SLUG}"
      ;;
    bitbucket)
      echo "  If this is a private Bitbucket repo, set the token:"
      echo "    gh secret set BITBUCKET_TOKEN --repo ${REPO_SLUG}"
      ;;
    gitea|codeberg)
      echo "  If this is a private Gitea/Codeberg repo, set the token:"
      echo "    gh secret set GITEA_TOKEN --repo ${REPO_SLUG}"
      ;;
    github)
      echo "  If this is a private GitHub repo, ensure SYNC_TOKEN has"
      echo "  repo scope and access to the source organisation."
      ;;
    *)
      echo "  Check the URL is correct and the repo is accessible."
      echo "  For private repos on self-hosted platforms, you may need"
      echo "  to add a custom token secret and update import-repo.sh."
      ;;
  esac
  echo "════════════════════════════════════════════════════════"
  error "Clone failed — see above for the fix."
fi

cd "$work_dir/repo.git"

gh_push_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${target_name}.git"

info "Pushing to ${GITHUB_OWNER}/${target_name}..."
attempt=0
push_ok=false
while [ "$attempt" -lt 3 ]; do
  push_out=$(git push --mirror "$gh_push_url" 2>&1) || true
  sanitized_out=$(echo "$push_out" | sanitize)

  if echo "$push_out" | grep -q "without \`workflow\` scope"; then
    echo "$sanitized_out"
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  SYNC_TOKEN is missing the 'workflow' scope."
    echo "  The source repo contains .github/workflows/ files."
    echo ""
    echo "  Regenerate the token at:"
    echo "    https://github.com/settings/tokens"
    echo "  ensuring the 'workflow' scope is checked, then update:"
    echo "    gh secret set SYNC_TOKEN --repo ${REPO_SLUG}"
    echo "════════════════════════════════════════════════════════"
    error "Push failed — see above for the fix."
  fi

  if ! echo "$push_out" | grep -q "remote rejected"; then
    echo "$sanitized_out"
    push_ok=true
    break
  fi

  attempt=$((attempt + 1))
  echo "$sanitized_out"
  [ "$attempt" -lt 3 ] && { info "  Push attempt ${attempt} failed, retrying in 5s..."; sleep 5; }
done

$push_ok || error "Mirror push to ${GITHUB_OWNER}/${target_name} failed after 3 attempts."
cd /
echo ""

# ── 6. Optionally push through OSP → OOC chain ───────────────────────────────

if [ "$MIRROR_TO_OSP_OOC" = "true" ]; then
  info "Registering in OSP + OOC mirror chain..."

  for org in "$OSP_ORG" "$OOC_ORG"; do
    info "  Checking ${org}/${target_name}..."
    org_existing=$(gh_api_get "${GH_API}/repos/${org}/${target_name}" 2>/dev/null \
      | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//' || echo "")

    if [ -n "$org_existing" ]; then
      info "  Already exists in ${org}."
    else
      info "  Creating ${org}/${target_name}..."
      payload=$(printf '{"name":"%s","description":"Mirrored from %s/%s","private":false}' \
        "$target_name" "$GITHUB_OWNER" "$target_name")
      response=$(gh_api_post "${GH_API}/orgs/${org}/repos" -d "$payload")
      http_code=$(echo "$response" | tail -1)
      if [ "$http_code" != "201" ]; then
        warn "Failed to create ${org}/${target_name} (HTTP ${http_code}) — skipping"
        continue
      fi
      info "  Created."
      sleep 3
    fi
  done

  # Push mirror into OSP immediately
  info "  Pushing ${GITHUB_OWNER}/${target_name} → ${OSP_ORG}/${target_name}..."
  osp_push_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${target_name}.git"
  git -C "$work_dir/repo.git" push --mirror "$osp_push_url" 2>&1 | sanitize || \
    warn "  OSP push failed — will be picked up by hourly mirror-to-osp.yml"

  info "  OOC will receive the push via setup-osp-mirrors.sh + mirror-osp-to-ooc.yaml (next :45/:15 run)."
  echo ""
fi

# ── 7. Optionally register for ongoing sync ───────────────────────────────────

if [ "$ONGOING_SYNC" = "true" ]; then
  info "Registering for ongoing sync in registered-imports.json..."

  IMPORTS_FILE="registered-imports.json"

  # Read current contents from GitHub
  file_meta=$(gh_api_get "${GH_API}/repos/${GITHUB_OWNER}/fork-sync-all/contents/${IMPORTS_FILE}" 2>/dev/null || echo "")
  file_sha=$(echo "$file_meta" | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//' || echo "")
  current_content=""
  if [ -n "$file_sha" ]; then
    current_content=$(echo "$file_meta" | grep -o '"content":"[^"]*"' | sed 's/"content":"//;s/"//' | tr -d '\n' | base64 -d 2>/dev/null || echo "[]")
  fi
  [ -z "$current_content" ] && current_content="[]"

  # Build new entry
  new_entry=$(printf '{"source_url":"%s","target_name":"%s","platform":"%s","added":"%s"}' \
    "$clean_url" "$target_name" "$platform" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

  # Check if already registered (by source_url)
  already=$(echo "$current_content" | grep -o "\"source_url\":\"${clean_url}\"" || echo "")
  if [ -n "$already" ]; then
    info "  Already registered — skipping."
  else
    # Append entry using python3 for safe JSON manipulation
    new_content=$(echo "$current_content" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entry = json.loads('${new_entry}')
data.append(entry)
print(json.dumps(data, indent=2))
")
    new_b64=$(echo "$new_content" | base64 -w0)

    # Commit back to fork-sync-all
    if [ -n "$file_sha" ]; then
      curl -sf -X PUT \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${GH_API}/repos/${GITHUB_OWNER}/fork-sync-all/contents/${IMPORTS_FILE}" \
        -d "{\"message\":\"register ${target_name} for ongoing sync (${platform})\",\"content\":\"${new_b64}\",\"sha\":\"${file_sha}\"}" \
        > /dev/null && info "  Registered." || warn "  Failed to update registered-imports.json"
    else
      curl -sf -X PUT \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${GH_API}/repos/${GITHUB_OWNER}/fork-sync-all/contents/${IMPORTS_FILE}" \
        -d "{\"message\":\"register ${target_name} for ongoing sync (${platform})\",\"content\":\"${new_b64}\"}" \
        > /dev/null && info "  Registered." || warn "  Failed to update registered-imports.json"
    fi
  fi
  echo ""
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo "========================================================"
echo "  Import complete"
echo ""
echo "  Source  : ${clean_url}"
echo "  Target  : github.com/${GITHUB_OWNER}/${target_name}"
if [ "$MIRROR_TO_OSP_OOC" = "true" ]; then
echo "  OSP     : github.com/${OSP_ORG}/${target_name}"
echo "  OOC     : github.com/${OOC_ORG}/${target_name} (pending next mirror run)"
fi
if [ "$ONGOING_SYNC" = "true" ]; then
echo "  Sync    : registered in registered-imports.json (hourly)"
fi
echo "========================================================"
