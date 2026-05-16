#!/usr/bin/env bash
#
# Monitors expiry and staleness of GitHub Actions secrets used by fork-sync-all.
#
# For each known secret:
#   - Checks when it was last updated in the repo (via GitHub API)
#   - Checks actual token expiry where the platform API supports it
#     (GitHub: /user endpoint headers, GitLab: /personal_access_tokens/self)
#   - Flags tokens expiring within WARN_DAYS (default: 30)
#   - Flags tokens not rotated within STALE_DAYS (default: 90)
#
# Outputs a structured report to GITHUB_STEP_SUMMARY and exits non-zero
# if any token needs attention (so the workflow can open/update an issue).
#
# Required env vars:
#   GH_TOKEN        — SYNC_TOKEN (repo + read:org scopes)
#   REPO            — owner/repo (Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   WARN_DAYS       — days before expiry to start warning (default: 30)
#   STALE_DAYS      — days since last rotation before flagging (default: 90)
#   GITLAB_TOKEN    — GITLAB_SYNC_TOKEN value (for expiry check)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

WARN_DAYS="${WARN_DAYS:-30}"
STALE_DAYS="${STALE_DAYS:-90}"
GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"

info()  { echo "[token-monitor] $*"; }
warn()  { echo "[token-monitor] ⚠️  $*"; }
ok()    { echo "[token-monitor] ✅ $*"; }
fail()  { echo "[token-monitor] ❌ $*"; }

now=$(date +%s)
issues=()   # accumulates problem descriptions
report=()   # accumulates markdown rows for summary

# ── Helpers ───────────────────────────────────────────────────────────────────

days_until() {
  local expiry_date="$1"
  local expiry_ts
  expiry_ts=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$expiry_date" +%s 2>/dev/null || echo 0)
  echo $(( (expiry_ts - now) / 86400 ))
}

days_since() {
  local updated_date="$1"
  local updated_ts
  updated_ts=$(date -d "$updated_date" +%s 2>/dev/null || echo 0)
  echo $(( (now - updated_ts) / 86400 ))
}

check_github_token_expiry() {
  local token="$1"
  # GitHub PAT expiry is in the response header x-oauth-token-expiration
  local expiry
  expiry=$(curl -sI \
    -H "Authorization: token ${token}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/user" \
    | grep -i "github-authentication-token-expiration:" \
    | sed 's/.*: //' | tr -d '\r' | awk '{print $1}')
  echo "${expiry:-unknown}"
}

check_gitlab_token_expiry() {
  local token="$1"
  local expiry
  expiry=$(curl -sf \
    -H "PRIVATE-TOKEN: ${token}" \
    "${GL_API}/personal_access_tokens/self" \
    | jq -r '.expires_at // "unknown"' 2>/dev/null || echo "unknown")
  echo "$expiry"
}

add_row() {
  local name="$1" last_rotated="$2" expiry="$3" status="$4" action="$5"
  report+=("| \`${name}\` | ${last_rotated} | ${expiry} | ${status} | ${action} |")
}

# ── 1. Fetch all secrets and their last-updated timestamps ────────────────────

info "Fetching secrets from ${REPO}..."
secrets_json=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API}/repos/${REPO}/actions/secrets") || {
  fail "Could not fetch secrets list — check SYNC_TOKEN scopes (needs: repo)"
  exit 1
}

# Known secrets and which platform token they hold
declare -A SECRET_PLATFORM=(
  [SYNC_TOKEN]="github"
  [GH_SYNC_TOKEN]="github"
  [ADD_MIRROR_REPO_SYNC]="github"
  [GITLAB_SYNC_TOKEN]="gitlab"
)

# OSP org secrets — cannot be read via API without admin:org scope on OSP.
# Tracked here by their backing PAT name and expiry for awareness.
# Format: "PAT_NAME|expiry_date|backs_secret|in_org"
OSP_ORG_SECRETS=(
  "OSP-ORG Mirror Token|2026-06-28|ORG_MIRROR_OSP_TO_OOC|OpenOS-Project-OSP"
  "sync-mirror-watchdog|2026-07-03|MIRROR_TOKEN|OpenOS-Project-OSP"
)

# ── 2. Check each known secret ────────────────────────────────────────────────

needs_attention=false

for secret_name in "${!SECRET_PLATFORM[@]}"; do
  platform="${SECRET_PLATFORM[$secret_name]}"
  info "Checking ${secret_name} (${platform})..."

  # Get last updated timestamp from API
  updated_at=$(echo "$secrets_json" | jq -r \
    --arg name "$secret_name" \
    '.secrets[] | select(.name == $name) | .updated_at' 2>/dev/null)

  if [[ -z "$updated_at" || "$updated_at" == "null" ]]; then
    fail "${secret_name} — not found in repo secrets"
    issues+=("**\`${secret_name}\`** is not set in the repo secrets.")
    add_row "$secret_name" "—" "—" "❌ Missing" "[Set it now](https://github.com/${REPO}/settings/secrets/actions)"
    needs_attention=true
    continue
  fi

  age_days=$(days_since "$updated_at")
  rotated_display="${updated_at:0:10} (${age_days}d ago)"

  # Check actual token expiry via platform API
  expiry="unknown"
  expiry_days=""

  case "$platform" in
    github)
      expiry=$(check_github_token_expiry "$GH_TOKEN")
      ;;
    gitlab)
      if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        expiry=$(check_gitlab_token_expiry "$GITLAB_TOKEN")
      else
        expiry="unknown (GITLAB_TOKEN not provided)"
      fi
      ;;
  esac

  if [[ "$expiry" != "unknown"* ]]; then
    expiry_days=$(days_until "$expiry")
    expiry_display="${expiry} (${expiry_days}d)"
  else
    expiry_display="$expiry"
  fi

  # Evaluate status
  status="✅ OK"
  action="—"
  rotate_url="https://github.com/${REPO}/actions/workflows/rotate-token.yml"
  pat_url="https://github.com/settings/tokens"

  if [[ -n "$expiry_days" && "$expiry_days" -le 0 ]]; then
    fail "${secret_name} — EXPIRED (${expiry})"
    status="❌ Expired"
    action="[Regenerate PAT](${pat_url}) then [rotate secret](${rotate_url})"
    issues+=("**\`${secret_name}\`** has **expired** (${expiry}). Regenerate and rotate immediately.")
    needs_attention=true
  elif [[ -n "$expiry_days" && "$expiry_days" -le "$WARN_DAYS" ]]; then
    warn "${secret_name} — expires in ${expiry_days} days (${expiry})"
    status="⚠️ Expiring soon"
    action="[Regenerate PAT](${pat_url}) then [rotate secret](${rotate_url})"
    issues+=("**\`${secret_name}\`** expires in **${expiry_days} days** (${expiry}). Rotate before it expires.")
    needs_attention=true
  elif [[ "$age_days" -ge "$STALE_DAYS" ]]; then
    warn "${secret_name} — not rotated in ${age_days} days"
    status="⚠️ Stale"
    action="[Rotate secret](${rotate_url})"
    issues+=("**\`${secret_name}\`** has not been rotated in **${age_days} days**. Consider rotating.")
    needs_attention=true
  else
    ok "${secret_name} — OK (expires: ${expiry_display}, rotated: ${age_days}d ago)"
  fi

  add_row "$secret_name" "$rotated_display" "$expiry_display" "$status" "$action"
done

# ── 3. Check OSP org secret backing PATs ─────────────────────────────────────
#
# OSP org secrets can't be read via API without admin:org on OSP.
# We track the backing PAT expiry directly instead.

osp_report=()

for entry in "${OSP_ORG_SECRETS[@]}"; do
  IFS='|' read -r pat_name expiry_date secret_name org <<< "$entry"
  info "Checking OSP org secret ${secret_name} (backed by PAT: ${pat_name})..."

  expiry_days=$(days_until "$expiry_date")
  expiry_display="${expiry_date} (${expiry_days}d)"
  status="✅ OK"
  action="—"
  pat_url="https://github.com/settings/tokens"
  org_url="https://github.com/organizations/${org}/settings/secrets/actions"

  if [[ "$expiry_days" -le 0 ]]; then
    fail "${pat_name} — EXPIRED"
    status="❌ Expired"
    action="[Regenerate PAT](${pat_url}) then [update org secret](${org_url})"
    issues+=("**\`${secret_name}\`** (OSP org secret) backing PAT **\`${pat_name}\`** has **expired**. Regenerate and update the org secret immediately.")
    needs_attention=true
  elif [[ "$expiry_days" -le "$WARN_DAYS" ]]; then
    warn "${pat_name} — expires in ${expiry_days} days"
    status="⚠️ Expiring soon"
    action="[Regenerate PAT](${pat_url}) then [update org secret](${org_url})"
    issues+=("**\`${secret_name}\`** (OSP org secret) backing PAT **\`${pat_name}\`** expires in **${expiry_days} days**. Rotate before it expires.")
    needs_attention=true
  else
    ok "${pat_name} — OK (expires: ${expiry_display})"
  fi

  osp_report+=("| \`${secret_name}\` | \`${org}\` | \`${pat_name}\` | ${expiry_display} | ${status} | ${action} |")
done

# ── 4. Write GitHub Step Summary ──────────────────────────────────────────────

{
  echo "## Token Monitor Report"
  echo ""
  echo "### Repository Secrets (fork-sync-all)"
  echo ""
  echo "| Secret | Last Rotated | Expiry | Status | Action |"
  echo "|---|---|---|---|---|"
  for row in "${report[@]}"; do
    echo "$row"
  done
  echo ""
  echo "### OSP Org Secrets (OpenOS-Project-OSP)"
  echo ""
  echo "> ℹ️ OSP org secret metadata cannot be read via API without admin:org scope. Expiry is tracked via the backing PAT."
  echo ""
  echo "| Secret | Org | Backing PAT | PAT Expiry | Status | Action |"
  echo "|---|---|---|---|---|---|"
  for row in "${osp_report[@]}"; do
    echo "$row"
  done
  echo ""
  if $needs_attention; then
    echo "### ⚠️ Action Required"
    echo ""
    for issue in "${issues[@]}"; do
      echo "- ${issue}"
    done
    echo ""
    echo "Use the [Rotate Secret Token](https://github.com/${REPO}/actions/workflows/rotate-token.yml) workflow to update repo secrets."
    echo "For OSP org secrets, update them at [OSP org secrets](https://github.com/organizations/OpenOS-Project-OSP/settings/secrets/actions)."
  else
    echo "### ✅ All tokens healthy"
    echo ""
    echo "No action required. Next check: $(date -d "+7 days" +%Y-%m-%d 2>/dev/null || date -v+7d +%Y-%m-%d)."
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# ── 4. Exit code signals whether action is needed ─────────────────────────────

if $needs_attention; then
  info "Action required — see summary above."
  exit 1
fi

info "All tokens healthy."
exit 0
