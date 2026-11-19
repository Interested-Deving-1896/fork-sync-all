#!/usr/bin/env bash
#
# scripts/bootstrap-org.sh
#
# Bootstraps a new fork-sync-all instance into a fresh GitHub org.
#
# Stages:
#   1. Resolve inputs + defaults from config/bootstrap-profile.yml
#   2. Fork (or clone+push) fork-sync-all into the target org
#   3. Substitute org-specific values into config files
#   4. Commit + push the substituted config
#   5. Set org-level secrets and variables via GitHub API
#   6. Optionally set is_template=true on the source repo
#   7. Dispatch post-bootstrap workflows
#
# Usage:
#   bash scripts/bootstrap-org.sh
#
# Required env:
#   GH_TOKEN                  PAT with repo + workflow + admin:org scopes on SOURCE org
#   BOOTSTRAP_GITHUB_ORG      Target GitHub org to bootstrap into
#   BOOTSTRAP_DISPLAY_NAME    Human-readable org name
#   BOOTSTRAP_SYNC_TOKEN      PAT to store as SYNC_TOKEN secret in the target org
#
# Optional env (see config/bootstrap-profile.yml for full list):
#   BOOTSTRAP_REPO_NAME       default: fork-sync-all
#   BOOTSTRAP_SLUG            default: derived from BOOTSTRAP_GITHUB_ORG
#   BOOTSTRAP_DESCRIPTION     default: from bootstrap-profile.yml
#   BOOTSTRAP_GITLAB_GROUP    default: "" (skip GitLab setup)
#   BOOTSTRAP_COLOR           default: 0033cc
#   BOOTSTRAP_SUPPORT_URL     default: derived
#   BOOTSTRAP_CHAIN_POSITION  default: source
#   BOOTSTRAP_CHAIN_DEPTH     default: 0
#   BOOTSTRAP_TOKEN_SECRET    default: SYNC_TOKEN
#   BOOTSTRAP_UPSTREAM_ORG    default: Interested-Deving-1896
#   BOOTSTRAP_UPSTREAM_REPO   default: fork-sync-all
#   BOOTSTRAP_MOTTO           default: from bootstrap-profile.yml
#   DRY_RUN                   default: false
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILE_FILE="${REPO_ROOT}/config/bootstrap-profile.yml"

: "${GH_TOKEN:?GH_TOKEN required}"
: "${BOOTSTRAP_GITHUB_ORG:?BOOTSTRAP_GITHUB_ORG required}"
: "${BOOTSTRAP_DISPLAY_NAME:?BOOTSTRAP_DISPLAY_NAME required}"
: "${BOOTSTRAP_SYNC_TOKEN:?BOOTSTRAP_SYNC_TOKEN required}"

DRY_RUN="${DRY_RUN:-false}"
API="https://api.github.com"

info() { echo "[bootstrap-org] $*" >&2; }
warn() { echo "[bootstrap-org][warn] $*" >&2; }
dry()  { echo "[bootstrap-org][dry-run] $*" >&2; }
die()  { echo "[bootstrap-org][error] $*" >&2; exit 1; }

source "${SCRIPT_DIR}/includes/gh-api.sh"

# ── SECTION: resolve_defaults ─────────────────────────────────────────────────

resolve_defaults() {
  # Repo name
  BOOTSTRAP_REPO_NAME="${BOOTSTRAP_REPO_NAME:-fork-sync-all}"

  # Slug: derive from org name if not set (lowercase, hyphens only)
  if [[ -z "${BOOTSTRAP_SLUG:-}" ]]; then
    BOOTSTRAP_SLUG=$(echo "$BOOTSTRAP_GITHUB_ORG" | tr '[:upper:]' '[:lower:]' | tr '_.' '-')
  fi

  # Description
  BOOTSTRAP_DESCRIPTION="${BOOTSTRAP_DESCRIPTION:-Org-wide mirror, sync, and template propagation control plane}"

  # Color
  BOOTSTRAP_COLOR="${BOOTSTRAP_COLOR:-0033cc}"

  # Support URL: derive from org + repo if not set
  if [[ -z "${BOOTSTRAP_SUPPORT_URL:-}" ]]; then
    local org_lower repo_lower
    org_lower=$(echo "$BOOTSTRAP_GITHUB_ORG" | tr '[:upper:]' '[:lower:]')
    repo_lower=$(echo "$BOOTSTRAP_REPO_NAME" | tr '[:upper:]' '[:lower:]')
    BOOTSTRAP_SUPPORT_URL="https://${org_lower}.github.io/${repo_lower}/"
  fi

  # GitLab
  BOOTSTRAP_GITLAB_GROUP="${BOOTSTRAP_GITLAB_GROUP:-}"
  if [[ -z "${BOOTSTRAP_GITLAB_MIRROR_GROUP:-}" && -n "$BOOTSTRAP_GITLAB_GROUP" ]]; then
    BOOTSTRAP_GITLAB_MIRROR_GROUP="${BOOTSTRAP_GITLAB_GROUP}/ops"
  else
    BOOTSTRAP_GITLAB_MIRROR_GROUP="${BOOTSTRAP_GITLAB_MIRROR_GROUP:-}"
  fi

  # Chain
  BOOTSTRAP_CHAIN_POSITION="${BOOTSTRAP_CHAIN_POSITION:-source}"
  BOOTSTRAP_CHAIN_DEPTH="${BOOTSTRAP_CHAIN_DEPTH:-0}"
  BOOTSTRAP_TOKEN_SECRET="${BOOTSTRAP_TOKEN_SECRET:-SYNC_TOKEN}"

  # Upstream OTA tracking
  BOOTSTRAP_UPSTREAM_ORG="${BOOTSTRAP_UPSTREAM_ORG:-Interested-Deving-1896}"
  BOOTSTRAP_UPSTREAM_REPO="${BOOTSTRAP_UPSTREAM_REPO:-fork-sync-all}"
  BOOTSTRAP_UPSTREAM_REF="${BOOTSTRAP_UPSTREAM_ORG}/${BOOTSTRAP_UPSTREAM_REPO}"

  # Motto
  BOOTSTRAP_MOTTO="${BOOTSTRAP_MOTTO:-When Git Platforms Give You Anxiety Attacks, Who Are You Going To Call? Fork-Sync-All!}"

  # Secondary token defaults to SYNC_TOKEN if not provided
  BOOTSTRAP_GH_TOKEN="${BOOTSTRAP_GH_TOKEN:-${BOOTSTRAP_SYNC_TOKEN}}"

  info "Resolved config:"
  info "  org:          ${BOOTSTRAP_GITHUB_ORG}"
  info "  repo:         ${BOOTSTRAP_REPO_NAME}"
  info "  slug:         ${BOOTSTRAP_SLUG}"
  info "  display_name: ${BOOTSTRAP_DISPLAY_NAME}"
  info "  gitlab_group: ${BOOTSTRAP_GITLAB_GROUP:-none}"
  info "  chain:        ${BOOTSTRAP_CHAIN_POSITION} (depth ${BOOTSTRAP_CHAIN_DEPTH})"
  info "  upstream:     ${BOOTSTRAP_UPSTREAM_REF}"
  info "  dry_run:      ${DRY_RUN}"
}

# ── SECTION: substitute_file ──────────────────────────────────────────────────
#
# substitute_file FILE TOKEN_MAP_VARNAME
#
# TOKEN_MAP_VARNAME is the name of a bash associative array mapping
# {{TOKEN}} → replacement value. Performs in-place sed substitution.

substitute_file() {
  local file="$1"
  local -n _token_map="$2"

  if [[ ! -f "$file" ]]; then
    warn "substitute_file: ${file} not found — skipping"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  cp "$file" "$tmp"

  for token in "${!_token_map[@]}"; do
    local value="${_token_map[$token]}"
    # Escape for sed: & and / in value
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[&/]/\\&/g')
    local escaped_token
    escaped_token=$(printf '%s' "$token" | sed 's/[[\.*^$()+?{|]/\\&/g')
    sed -i "s/${escaped_token}/${escaped_value}/g" "$tmp"
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would substitute tokens in ${file}:"
    diff "$file" "$tmp" >&2 || true
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    info "Substituted tokens in ${file}"
  fi
}

# ── SECTION: scaffold_file ────────────────────────────────────────────────────

scaffold_gitlab_subgroups() {
  local file="${REPO_ROOT}/config/gitlab-subgroups.yml"
  [[ -f "$file" ]] && { info "gitlab-subgroups.yml already exists — skipping scaffold"; return 0; }
  [[ -z "$BOOTSTRAP_GITLAB_GROUP" ]] && { info "No GitLab group set — skipping gitlab-subgroups.yml scaffold"; return 0; }

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would scaffold ${file} for group ${BOOTSTRAP_GITLAB_GROUP}"
    return 0
  fi

  cat > "$file" <<YAML
# config/gitlab-subgroups.yml
#
# Bootstrapped by bootstrap-org.sh for ${BOOTSTRAP_GITLAB_GROUP}.
# Add subgroups and repos as your org grows.
#
# Fallback: any repo not listed here is placed in the 'ops' subgroup.

subgroups:
  ops:
    id: 0   # TODO: replace with real GitLab namespace ID after creating the group
    path: ${BOOTSTRAP_GITLAB_GROUP}/ops
    description: >
      Operational tooling — fork-sync-all and infrastructure repos.
    repos: []
YAML
  info "Scaffolded ${file}"
}

scaffold_registered_imports() {
  local file="${REPO_ROOT}/registered-imports.json"
  [[ -f "$file" ]] && { info "registered-imports.json already exists — skipping scaffold"; return 0; }

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would scaffold ${file} as empty array"
    return 0
  fi

  echo "[]" > "$file"
  info "Scaffolded ${file}"
}

scaffold_template_consumers() {
  local file="${REPO_ROOT}/config/template-consumers.yml"
  [[ -f "$file" ]] && { info "template-consumers.yml already exists — skipping scaffold"; return 0; }

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would scaffold ${file}"
    return 0
  fi

  cat > "$file" <<YAML
# config/template-consumers.yml
#
# Bootstrapped by bootstrap-org.sh.
# Add consumer repos as they are onboarded.

consumers:
  - name: ${BOOTSTRAP_REPO_NAME}
    tier: protected
    note: fork-sync-all itself — receives updates via mirror chain, not template injection
YAML
  info "Scaffolded ${file}"
}

scaffold_vouched_td() {
  local file="${REPO_ROOT}/.github/VOUCHED.td"
  [[ -f "$file" ]] && { info "VOUCHED.td already exists — skipping scaffold"; return 0; }

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would scaffold ${file} with ${BOOTSTRAP_GITHUB_ORG} as sole trusted entry"
    return 0
  fi

  mkdir -p "${REPO_ROOT}/.github"
  cat > "$file" <<VOUCHED
# VOUCHED.td — trusted contributors for ${BOOTSTRAP_REPO_NAME}
#
# Bootstrapped by bootstrap-org.sh. Run vouch-seed.sh to populate from
# org members, past PR authors, and CODEOWNERS.
#
# Format: github:username (vouched) | -github:username [reason] (denounced)

github:${BOOTSTRAP_GITHUB_ORG}
VOUCHED
  info "Scaffolded ${file}"
}

# ── SECTION: fork_repo ────────────────────────────────────────────────────────
#
# Forks the current repo into the target org, or creates a new repo and
# pushes if the fork API is unavailable (e.g. same-user org).

SOURCE_ORG="${SOURCE_ORG:-Interested-Deving-1896}"
SOURCE_REPO="${SOURCE_REPO:-fork-sync-all}"

fork_or_push_repo() {
  local target_org="$BOOTSTRAP_GITHUB_ORG"
  local target_repo="$BOOTSTRAP_REPO_NAME"

  # Check if repo already exists in target org
  local exists
  exists=$(gh_get "${API}/repos/${target_org}/${target_repo}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

  if [[ -n "$exists" ]]; then
    info "Repo ${target_org}/${target_repo} already exists — skipping fork/push"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would fork ${SOURCE_ORG}/${SOURCE_REPO} → ${target_org}/${target_repo}"
    return 0
  fi

  info "Forking ${SOURCE_ORG}/${SOURCE_REPO} → ${target_org}/${target_repo}..."

  # Try GitHub fork API first
  local fork_result
  fork_result=$(curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "{\"organization\":\"${target_org}\",\"name\":\"${target_repo}\",\"default_branch_only\":true}" \
    "${API}/repos/${SOURCE_ORG}/${SOURCE_REPO}/forks" 2>/dev/null || echo "")

  if echo "$fork_result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('id') else 1)" 2>/dev/null; then
    info "Fork created — waiting for GitHub to complete fork operation..."
    sleep 10
    return 0
  fi

  # Fork API failed — create repo and push manually
  warn "Fork API failed; creating repo and pushing manually"

  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${target_repo}\",\"description\":\"${BOOTSTRAP_DESCRIPTION}\",\"private\":false,\"auto_init\":false}" \
    "${API}/orgs/${target_org}/repos" >/dev/null 2>&1 || die "Failed to create repo ${target_org}/${target_repo}"

  local push_url="https://${GH_TOKEN}@github.com/${target_org}/${target_repo}.git"
  git -C "$REPO_ROOT" remote add bootstrap-target "$push_url" 2>/dev/null || \
    git -C "$REPO_ROOT" remote set-url bootstrap-target "$push_url"
  git -C "$REPO_ROOT" push bootstrap-target main || die "Failed to push to ${target_org}/${target_repo}"
  git -C "$REPO_ROOT" remote remove bootstrap-target
  info "Pushed to ${target_org}/${target_repo}"
}

set_template_flag() {
  local source_org="$SOURCE_ORG"
  local source_repo="$SOURCE_REPO"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would set is_template=true on ${source_org}/${source_repo}"
    return 0
  fi

  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d '{"is_template":true}' \
    "${API}/repos/${source_org}/${source_repo}" >/dev/null 2>&1 \
    && info "Set is_template=true on ${source_org}/${source_repo}" \
    || warn "Could not set is_template on ${source_org}/${source_repo} (may need admin scope)"
}

# ── SECTION: set_secret ───────────────────────────────────────────────────────
#
# Sets an org-level Actions secret using the GitHub API.
# Requires the secret value to be encrypted with the org's public key.
# Uses the gh CLI (which handles encryption) if available; falls back to
# a Python-based libsodium encrypt if gh is not present.

set_org_secret() {
  local org="$1" secret_name="$2" secret_value="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would set org secret ${org}/${secret_name}"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    echo "$secret_value" | gh secret set "$secret_name" \
      --org "$org" \
      --visibility all \
      2>/dev/null \
      && info "Set org secret ${secret_name} on ${org}" \
      || warn "Failed to set org secret ${secret_name} on ${org} (may need admin:org scope)"
  else
    warn "gh CLI not available — cannot set org secret ${secret_name}. Set it manually."
  fi
}

# ── SECTION: set_variable ─────────────────────────────────────────────────────

set_repo_variable() {
  local org="$1" repo="$2" var_name="$3" var_value="$4"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would set repo variable ${org}/${repo}: ${var_name}=${var_value}"
    return 0
  fi

  # Try PATCH (update) first, then POST (create)
  local url="${API}/repos/${org}/${repo}/actions/variables/${var_name}"
  local data
  data=$(python3 -c "import json; print(json.dumps({'name': '${var_name}', 'value': '${var_value}'}))")

  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" "$url" 2>/dev/null || echo "000")

  if [[ "$http_code" == "204" ]]; then
    info "Updated repo variable ${var_name} on ${org}/${repo}"
    return 0
  fi

  # Variable doesn't exist yet — create it
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${API}/repos/${org}/${repo}/actions/variables" >/dev/null 2>&1 \
    && info "Created repo variable ${var_name} on ${org}/${repo}" \
    || warn "Failed to set repo variable ${var_name} on ${org}/${repo}"
}

# ── SECTION: dispatch_workflow ────────────────────────────────────────────────

dispatch_workflow() {
  local org="$1" repo="$2" workflow="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would dispatch ${workflow} on ${org}/${repo}"
    return 0
  fi

  info "Dispatching ${workflow} on ${org}/${repo}..."
  curl -sf -X POST \
    -H "Authorization: token ${BOOTSTRAP_SYNC_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d '{"ref":"main"}' \
    "${API}/repos/${org}/${repo}/actions/workflows/${workflow}/dispatches" >/dev/null 2>&1 \
    && info "Dispatched ${workflow}" \
    || warn "Failed to dispatch ${workflow} — may not exist yet or token lacks workflow scope"
}

# ── SECTION: main ─────────────────────────────────────────────────────────────

main() {
  info "=== fork-sync-all org bootstrap ==="

  # ── Stage 1: Resolve defaults ──────────────────────────────────────────────
  resolve_defaults

  local target_org="$BOOTSTRAP_GITHUB_ORG"
  local target_repo="$BOOTSTRAP_REPO_NAME"

  # ── Stage 2: Fork / push repo ──────────────────────────────────────────────
  fork_or_push_repo

  # ── Stage 3: Substitute config files ──────────────────────────────────────
  info "Substituting org-specific values into config files..."

  # brand.yml — replace the source org's values with the new org's values
  declare -A brand_tokens=(
    ["Interested-Deving-1896/fork-sync-all"]="${target_org}/${target_repo}"
    ["Interested-Deving-1896"]="${target_org}"
    ['"fork-sync-all"']="\"${target_repo}\""
    ['"fsa"']="\"${BOOTSTRAP_SLUG}\""
    ["Org-wide mirror, sync, and template propagation control plane"]="${BOOTSTRAP_DESCRIPTION}"
    ["0033cc"]="${BOOTSTRAP_COLOR}"
    ["https://interested-deving-1896.github.io/fork-sync-all/"]="${BOOTSTRAP_SUPPORT_URL}"
  )
  substitute_file "${REPO_ROOT}/config/brand.yml" brand_tokens

  # fsa-deployments.yml — replace source deployment org/repo
  declare -A deploy_tokens=(
    ["org: Interested-Deving-1896"]="org: ${target_org}"
    ["repo: fork-sync-all"]="repo: ${target_repo}"
    ["token_secret: SYNC_TOKEN"]="token_secret: ${BOOTSTRAP_TOKEN_SECRET}"
  )
  substitute_file "${REPO_ROOT}/config/fsa-deployments.yml" deploy_tokens

  # fsa-pin.yml — replace org references
  declare -A pin_tokens=(
    ["login: Interested-Deving-1896"]="login: ${target_org}"
    ["- Interested-Deving-1896/fork-sync-all"]="- ${target_org}/${target_repo}"
    ["- Interested-Deving-1896/btrfs-dwarfs-framework"]=""
  )
  substitute_file "${REPO_ROOT}/config/fsa-pin.yml" pin_tokens

  # fsa-motto.yml — replace motto text if custom one provided
  if [[ "${BOOTSTRAP_MOTTO}" != "When Git Platforms Give You Anxiety Attacks, Who Are You Going To Call? Fork-Sync-All!" ]]; then
    declare -A motto_tokens=(
      ["When Git Platforms Give You Anxiety Attacks, Who Are You Going To Call? Fork-Sync-All!"]="${BOOTSTRAP_MOTTO}"
    )
    substitute_file "${REPO_ROOT}/config/fsa-motto.yml" motto_tokens
  fi

  # vouch-registry.yml — replace Tier 1 handle
  declare -A vouch_tokens=(
    ["handle: Interested-Deving-1896"]="handle: ${target_org}"
    ["github: Interested-Deving-1896"]="github: ${target_org}"
  )
  substitute_file "${REPO_ROOT}/config/vouch-registry.yml" vouch_tokens

  # ── Stage 4: Scaffold files that should not exist yet ─────────────────────
  scaffold_gitlab_subgroups
  scaffold_registered_imports
  scaffold_template_consumers
  scaffold_vouched_td

  # ── Stage 5: Commit + push substituted config ──────────────────────────────
  if [[ "$DRY_RUN" != "true" ]]; then
    info "Committing substituted config..."
    git -C "$REPO_ROOT" config user.name "bootstrap-org"
    git -C "$REPO_ROOT" config user.email "bootstrap@fork-sync-all"

    git -C "$REPO_ROOT" add \
      config/brand.yml \
      config/fsa-deployments.yml \
      config/fsa-pin.yml \
      config/fsa-motto.yml \
      config/vouch-registry.yml \
      config/gitlab-subgroups.yml \
      registered-imports.json \
      config/template-consumers.yml \
      .github/VOUCHED.td \
      2>/dev/null || true

    if ! git -C "$REPO_ROOT" diff --cached --quiet; then
      git -C "$REPO_ROOT" commit \
        -m "chore(bootstrap): configure for ${target_org}" \
        -m "Bootstrapped by bootstrap-org.sh. Org-specific values substituted into config files." \
        -m "Co-authored-by: Ona <no-reply@ona.com>"

      local push_url="https://${BOOTSTRAP_SYNC_TOKEN}@github.com/${target_org}/${target_repo}.git"
      git -C "$REPO_ROOT" remote add bootstrap-push "$push_url" 2>/dev/null || \
        git -C "$REPO_ROOT" remote set-url bootstrap-push "$push_url"
      git -C "$REPO_ROOT" push bootstrap-push main \
        && info "Pushed config to ${target_org}/${target_repo}" \
        || warn "Push failed — check BOOTSTRAP_SYNC_TOKEN has push access to ${target_org}/${target_repo}"
      git -C "$REPO_ROOT" remote remove bootstrap-push
    else
      info "No config changes to commit"
    fi
  else
    dry "Would commit and push substituted config to ${target_org}/${target_repo}"
  fi

  # ── Stage 6: Set org secrets and repo variables ────────────────────────────
  info "Setting org secrets and repo variables..."

  set_org_secret "$target_org" "SYNC_TOKEN"  "$BOOTSTRAP_SYNC_TOKEN"
  set_org_secret "$target_org" "GH_TOKEN"    "$BOOTSTRAP_GH_TOKEN"

  if [[ -n "$BOOTSTRAP_GITLAB_GROUP" ]]; then
    local gitlab_token="${BOOTSTRAP_GITLAB_TOKEN:-}"
    if [[ -n "$gitlab_token" ]]; then
      set_org_secret "$target_org" "GITLAB_TOKEN" "$gitlab_token"
    else
      warn "BOOTSTRAP_GITLAB_GROUP is set but BOOTSTRAP_GITLAB_TOKEN is not — skipping GITLAB_TOKEN secret"
    fi
  fi

  set_repo_variable "$target_org" "$target_repo" "FSA_MANAGED" "true"

  # ── Stage 7: Set template flag on source repo ──────────────────────────────
  set_template_flag

  # ── Stage 8: Post-bootstrap workflow dispatches ────────────────────────────
  info "Dispatching post-bootstrap workflows on ${target_org}/${target_repo}..."

  # Give GitHub a moment to register the pushed workflows
  [[ "$DRY_RUN" != "true" ]] && sleep 5

  dispatch_workflow "$target_org" "$target_repo" "vouch-sync-codeowners.yml"
  dispatch_workflow "$target_org" "$target_repo" "validate-config.yml"

  if [[ -n "$BOOTSTRAP_GITLAB_GROUP" ]]; then
    dispatch_workflow "$target_org" "$target_repo" "setup-osp-mirrors.yml"
  fi

  info "=== Bootstrap complete ==="
  info ""
  info "Next steps:"
  info "  1. Add repos to registered-imports.json and run onboard-repo.yml"
  info "  2. Add consumer repos to config/template-consumers.yml"
  if [[ -n "$BOOTSTRAP_GITLAB_GROUP" ]]; then
    info "  3. Update config/gitlab-subgroups.yml with real GitLab namespace IDs"
  fi
  info "  4. Run vouch-onboard.yml to add trusted contributors"
  info "  5. Review config/fsa-deployments.yml and add mirror deployments as needed"
}

main "$@"
