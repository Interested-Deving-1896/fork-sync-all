#!/usr/bin/env bash
#
# Updates a named GitHub Actions secret and optionally validates the new
# token against its platform API.
#
# Handles two secret locations:
#   repo    — secrets in Interested-Deving-1896/fork-sync-all (default)
#   osp-org — org-level secrets in OpenOS-Project-OSP
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with secrets:write on REPO (SYNC_TOKEN)
#   SECRET_NAME   — name of the secret to update
#   TOKEN_VALUE   — new token value (never echoed)
#   REPO          — owner/repo (Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   VALIDATE        — "true" to validate the token before storing (default: true)
#   SECRET_LOCATION — "repo" or "osp-org" (default: auto-detected from SECRET_NAME)
#   NEW_EXPIRY_DATE — new expiry date (YYYY-MM-DD) to write into token-monitor.sh
#                     and AGENTS.md after rotation (optional)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SECRET_NAME:?SECRET_NAME is required}"
: "${TOKEN_VALUE:?TOKEN_VALUE is required}"
: "${REPO:?REPO is required}"

VALIDATE="${VALIDATE:-true}"
NEW_EXPIRY_DATE="${NEW_EXPIRY_DATE:-}"

info() { echo "[rotate-token] $*" >&2; }
ok()   { echo "[rotate-token] ✓ $*"; }
fail() { echo "[rotate-token] ✗ $*" >&2; exit 1; }

# ── 1. Detect platform and location from secret name ─────────────────────────

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

# Auto-detect location: OSP org secrets live in OpenOS-Project-OSP
SECRET_LOCATION="${SECRET_LOCATION:-}"
if [[ -z "$SECRET_LOCATION" ]]; then
  case "${SECRET_NAME}" in
    ORG_MIRROR_OSP_TO_OOC|MIRROR_TOKEN)
      SECRET_LOCATION="osp-org" ;;
    *)
      SECRET_LOCATION="repo" ;;
  esac
fi

OSP_ORG="OpenOS-Project-OSP"

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

if [[ "$SECRET_LOCATION" == "osp-org" ]]; then
  info "Updating org secret ${SECRET_NAME} in ${OSP_ORG}..."

  # GitHub org secrets API requires the public key to encrypt the value.
  # Fetch the org's public key first.
  key_json=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${OSP_ORG}/actions/secrets/public-key") || \
    fail "Could not fetch public key for ${OSP_ORG} — check that GH_TOKEN has admin:org scope on ${OSP_ORG}."

  key_id=$(echo "$key_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['key_id'])")
  pub_key=$(echo "$key_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")

  # Encrypt the secret value using libsodium (PyNaCl) — required by GitHub API.
  encrypted=$(python3 - <<PYEOF
import base64, sys
from nacl import encoding, public

pub_key_bytes = base64.b64decode("${pub_key}")
sealed = public.SealedBox(public.PublicKey(pub_key_bytes))
encrypted = sealed.encrypt("${TOKEN_VALUE}".encode())
print(base64.b64encode(encrypted).decode())
PYEOF
  ) || fail "Encryption failed — ensure PyNaCl is installed (pip install pynacl)."

  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${OSP_ORG}/actions/secrets/${SECRET_NAME}" \
    -d "{\"encrypted_value\":\"${encrypted}\",\"key_id\":\"${key_id}\",\"visibility\":\"all\"}")

  if [[ "$http_code" == "201" || "$http_code" == "204" ]]; then
    ok "${SECRET_NAME} updated in ${OSP_ORG} org (HTTP ${http_code})."
  else
    fail "Failed to update ${SECRET_NAME} in ${OSP_ORG} org (HTTP ${http_code})."
  fi

else
  info "Updating repo secret ${SECRET_NAME} in ${REPO}..."

  # Pipe via stdin — never passed as a shell argument to avoid appearing in
  # process listings or being captured by log scrapers.
  printf '%s' "${TOKEN_VALUE}" \
    | gh secret set "${SECRET_NAME}" --repo "${REPO}" --body -

  ok "${SECRET_NAME} updated."
fi
echo ""

# ── 4. Confirm the secret is present ─────────────────────────────────────────

if [[ "$SECRET_LOCATION" == "osp-org" ]]; then
  secret_check=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${OSP_ORG}/actions/secrets/${SECRET_NAME}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
  check_label="${OSP_ORG} org"
else
  secret_check=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/secrets/${SECRET_NAME}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
  check_label="${REPO}"
fi

if [[ "$secret_check" == "${SECRET_NAME}" ]]; then
  ok "${SECRET_NAME} confirmed present in ${check_label}."
else
  fail "Could not confirm ${SECRET_NAME} in ${check_label} after update."
fi

# ── 5. Update expiry dates in token-monitor.sh and AGENTS.md ─────────────────
# Only runs when NEW_EXPIRY_DATE is provided and we're in a git checkout.

if [[ -n "$NEW_EXPIRY_DATE" ]]; then
  info "Updating expiry date to ${NEW_EXPIRY_DATE} in tracked files..."

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  MONITOR_SH="${REPO_ROOT}/scripts/token-monitor.sh"
  AGENTS_MD="${REPO_ROOT}/AGENTS.md"

  updated_files=()

  # Use Python for reliable in-place substitution — avoids sed portability issues.
  python3 - <<PYEOF
import re, sys

secret  = "${SECRET_NAME}"
new_exp = "${NEW_EXPIRY_DATE}"
monitor = "${MONITOR_SH}"
agents  = "${AGENTS_MD}"

def update_file(path, pattern, replacement, label):
    try:
        text = open(path).read()
    except FileNotFoundError:
        print(f"[rotate-token] {path} not found — skipping {label}", flush=True)
        return False
    new_text, n = re.subn(pattern, replacement, text)
    if n == 0:
        print(f"[rotate-token] No match for {secret} in {label} — skipping", flush=True)
        return False
    open(path, "w").write(new_text)
    print(f"[rotate-token] ✓ Updated expiry in {label}", flush=True)
    return True

# token-monitor.sh: "PAT Name|2026-06-28|SECRET_NAME|Org"
update_file(
    monitor,
    rf'(\|)[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}(\|{re.escape(secret)}\|)',
    rf'\g<1>{new_exp}\g<2>',
    "token-monitor.sh"
)

# AGENTS.md: | \`SECRET_NAME\` | ... | **2026-06-28** | ...
update_file(
    agents,
    rf'(\| `{re.escape(secret)}` \|(?:[^|]*\|){{2}})\s*\*\*[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}\*\*',
    rf'\g<1> **{new_exp}**',
    "AGENTS.md"
)
PYEOF

  # Collect modified files for the commit
  for f in "$MONITOR_SH" "$AGENTS_MD"; do
    rel="${f#${REPO_ROOT}/}"
    git -C "$REPO_ROOT" diff --quiet "$rel" 2>/dev/null || updated_files+=("$rel")
  done

  # Commit the updated files if inside a git repo
  if [[ ${#updated_files[@]} -gt 0 ]] && git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null; then
    git -C "$REPO_ROOT" add "${updated_files[@]/#/${REPO_ROOT}/}" 2>/dev/null || true
    git -C "$REPO_ROOT" commit \
      -m "chore(tokens): update ${SECRET_NAME} expiry to ${NEW_EXPIRY_DATE}" \
      --author "github-actions[bot] <github-actions[bot]@users.noreply.github.com>" \
      2>/dev/null && ok "Committed expiry date update." || info "Nothing to commit (dates may already be current)."
  fi
fi

# ── 7. Print management link ──────────────────────────────────────────────────

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
