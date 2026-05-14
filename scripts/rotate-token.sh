#!/usr/bin/env bash
#
# Updates a named GitHub Actions secret and optionally validates the new
# token against its platform API.
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with secrets:write on REPO (SYNC_TOKEN)
#   SECRET_NAME   — name of the secret to update
#   TOKEN_VALUE   — new token value (never echoed)
#   REPO          — owner/repo (Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   VALIDATE      — "true" to validate the token before storing (default: true)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SECRET_NAME:?SECRET_NAME is required}"
: "${TOKEN_VALUE:?TOKEN_VALUE is required}"
: "${REPO:?REPO is required}"

VALIDATE="${VALIDATE:-true}"

info() { echo "[rotate-token] $*"; }
ok()   { echo "[rotate-token] ✓ $*"; }
fail() { echo "[rotate-token] ✗ $*" >&2; exit 1; }

# ── 1. Detect platform from secret name ──────────────────────────────────────

platform=""
case "${SECRET_NAME}" in
  SYNC_TOKEN|GH_SYNC_TOKEN|ADD_MIRROR_REPO_SYNC)
    platform="github" ;;
  GITLAB_SYNC_TOKEN)
    platform="gitlab" ;;
  BITBUCKET_TOKEN)
    platform="bitbucket" ;;
  GITEA_TOKEN)
    platform="gitea" ;;
esac

# ── 2. Validate token against platform API (before storing) ──────────────────
# Validate first so a bad token is caught before it overwrites a working one.

if [[ "${VALIDATE}" == "true" && -n "$platform" ]]; then
  info "Validating new token against ${platform} API..."

  case "${platform}" in
    github)
      login=$(curl -sf \
        -H "Authorization: token ${TOKEN_VALUE}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || echo "")
      if [[ -z "$login" ]]; then
        fail "GitHub token validation failed — token may be invalid or expired."
      fi
      ok "GitHub token valid (login: ${login})."

      # Report scopes so the operator can confirm required ones are present
      scopes=$(curl -sI \
        -H "Authorization: token ${TOKEN_VALUE}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user" \
        | grep -i '^x-oauth-scopes:' | tr -d '\r' | sed 's/x-oauth-scopes: //i')
      [[ -n "$scopes" ]] && info "Token scopes: ${scopes}"
      ;;

    gitlab)
      gl_user=$(curl -sf \
        -H "PRIVATE-TOKEN: ${TOKEN_VALUE}" \
        "https://gitlab.com/api/v4/user" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")
      if [[ -z "$gl_user" ]]; then
        fail "GitLab token validation failed — token may be invalid or expired."
      fi
      ok "GitLab token valid (username: ${gl_user})."

      gl_expiry=$(curl -sf \
        -H "PRIVATE-TOKEN: ${TOKEN_VALUE}" \
        "https://gitlab.com/api/v4/personal_access_tokens/self" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('expires_at','unknown'))" 2>/dev/null || echo "unknown")
      info "Token expires: ${gl_expiry}"
      ;;

    bitbucket)
      # Bitbucket app passwords require Basic auth with a username, which we
      # don't have here. Skip live validation and warn the operator.
      info "Bitbucket app passwords require Basic auth with a username."
      info "Cannot validate without a username — skipping live check."
      info "The secret will be stored; verify manually that it works."
      ;;

    gitea)
      # Gitea instance URL varies — skip live validation.
      info "Gitea token validation requires the instance URL — skipping live check."
      info "The secret will be stored; verify manually that it works."
      ;;
  esac
  echo ""
fi

# ── 3. Update the secret ──────────────────────────────────────────────────────

info "Updating ${SECRET_NAME} in ${REPO}..."

# Pipe via stdin — never passed as a shell argument to avoid appearing in
# process listings or being captured by log scrapers.
printf '%s' "${TOKEN_VALUE}" \
  | gh secret set "${SECRET_NAME}" --repo "${REPO}" --body -

ok "${SECRET_NAME} updated."
echo ""

# ── 4. Confirm the secret is present ─────────────────────────────────────────

secret_check=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/secrets/${SECRET_NAME}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

if [[ "$secret_check" == "${SECRET_NAME}" ]]; then
  ok "${SECRET_NAME} confirmed present in ${REPO}."
else
  fail "Could not confirm ${SECRET_NAME} in ${REPO} after update."
fi

# ── 5. Print management link ──────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ${SECRET_NAME} rotated successfully."
echo ""
case "${platform}" in
  github)
    echo "  Manage at: https://github.com/settings/tokens"
    ;;
  gitlab)
    echo "  Manage at: https://gitlab.com/-/user_settings/personal_access_tokens"
    ;;
  bitbucket)
    echo "  Manage at: https://bitbucket.org/account/settings/app-passwords/"
    ;;
  gitea)
    echo "  Manage at: your Gitea instance → Settings → Applications"
    ;;
  *)
    echo "  Manage at: the platform where this token was issued."
    ;;
esac
echo "════════════════════════════════════════════════════════"

exit 0
