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
#                     and AGENTS.md after rotation (optional; auto-detected if blank)
#
# OSP org secret rotation requires a token with admin:org on OpenOS-Project-OSP.
# Resolution order (first available wins):
#   1. OSP_APP_PRIVATE_KEY + OSP_APP_ID  — GitHub App installation token (preferred)
#   2. OSP_ADMIN_TOKEN                   — PAT with admin:org on OpenOS-Project-OSP
#   3. GH_TOKEN                          — falls back with a clear error if it 403s

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SECRET_NAME:?SECRET_NAME is required}"
: "${TOKEN_VALUE:?TOKEN_VALUE is required}"
: "${REPO:?REPO is required}"

VALIDATE="${VALIDATE:-true}"
NEW_EXPIRY_DATE="${NEW_EXPIRY_DATE:-}"   # auto-detected from platform API if blank

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

# ── OSP org token resolution ──────────────────────────────────────────────────
# Resolves the token used for OpenOS-Project-OSP org API calls.
# Priority: GitHub App > OSP_ADMIN_TOKEN PAT > GH_TOKEN (with 403 detection).

OSP_APP_ID="${OSP_APP_ID:-}"
OSP_APP_PRIVATE_KEY="${OSP_APP_PRIVATE_KEY:-}"
OSP_ADMIN_TOKEN="${OSP_ADMIN_TOKEN:-}"

resolve_osp_token() {
  # 1. GitHub App installation token
  if [[ -n "$OSP_APP_ID" && -n "$OSP_APP_PRIVATE_KEY" ]]; then
    info "Obtaining GitHub App installation token for ${OSP_ORG}..."
    app_token=$(python3 - <<PYEOF
import time, base64, json, urllib.request, urllib.error

app_id    = "${OSP_APP_ID}"
pem       = """${OSP_APP_PRIVATE_KEY}"""
org       = "${OSP_ORG}"

# Build JWT
try:
    from cryptography.hazmat.primitives import serialization, hashes
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.backends import default_backend
    import jwt as pyjwt
except ImportError:
    print("ERROR: cryptography and PyJWT required for App auth (pip install cryptography PyJWT)", flush=True)
    raise SystemExit(1)

now = int(time.time())
payload = {"iat": now - 60, "exp": now + 540, "iss": app_id}
token = pyjwt.encode(payload, pem, algorithm="RS256")
if isinstance(token, bytes):
    token = token.decode()

# Get installation ID for the org
req = urllib.request.Request(
    f"https://api.github.com/orgs/{org}/installation",
    headers={"Authorization": f"Bearer {token}",
             "Accept": "application/vnd.github+json"})
try:
    with urllib.request.urlopen(req) as r:
        install_id = json.loads(r.read())["id"]
except urllib.error.HTTPError as e:
    print(f"ERROR: Could not get installation for {org}: HTTP {e.code}", flush=True)
    raise SystemExit(1)

# Exchange for installation access token
req2 = urllib.request.Request(
    f"https://api.github.com/app/installations/{install_id}/access_tokens",
    data=b"{}",
    headers={"Authorization": f"Bearer {token}",
             "Accept": "application/vnd.github+json"},
    method="POST")
with urllib.request.urlopen(req2) as r:
    print(json.loads(r.read())["token"])
PYEOF
    ) || { warn "GitHub App token exchange failed — falling back to OSP_ADMIN_TOKEN or GH_TOKEN."; app_token=""; }

    if [[ -n "$app_token" && "$app_token" != ERROR* ]]; then
      info "GitHub App installation token obtained."
      echo "$app_token"
      return 0
    fi
  fi

  # 2. Dedicated OSP admin PAT
  if [[ -n "$OSP_ADMIN_TOKEN" ]]; then
    info "Using OSP_ADMIN_TOKEN for ${OSP_ORG} org operations."
    echo "$OSP_ADMIN_TOKEN"
    return 0
  fi

  # 3. Fall back to GH_TOKEN — will 403 if it lacks admin:org on OSP
  info "No OSP_APP_* or OSP_ADMIN_TOKEN set — using GH_TOKEN (may 403 if it lacks admin:org on ${OSP_ORG})."
  echo "$GH_TOKEN"
}

# ── 2. Validate token against platform API (before storing) ──────────────────
# Validate first so a bad token is caught before it overwrites a working one.

if [[ "${VALIDATE}" == "true" && -n "$platform" ]]; then
  info "Validating new token against ${platform} API..."

  case "${platform}" in
    github)
      # Fetch headers from /rate_limit — reliably returns the expiry header
      # and costs 1 call. /user body used separately for login validation.
      gh_response=$(curl -sI \
        -H "Authorization: token ${TOKEN_VALUE}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/rate_limit")

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
      scopes=$(echo "$gh_response" | grep -i '^x-oauth-scopes:' | tr -d '\r' | sed 's/x-oauth-scopes: //i')
      [[ -n "$scopes" ]] && info "Token scopes: ${scopes}"

      # Auto-detect expiry from response header (YYYY-MM-DD HH:MM:SS UTC → YYYY-MM-DD)
      detected_expiry=$(echo "$gh_response" \
        | grep -i '^github-authentication-token-expiration:' \
        | tr -d '\r' | sed 's/.*: //' | awk '{print $1}')
      if [[ -n "$detected_expiry" ]]; then
        info "Token expiry detected: ${detected_expiry}"
        [[ -z "$NEW_EXPIRY_DATE" ]] && NEW_EXPIRY_DATE="$detected_expiry" && \
          info "Will update tracked expiry to ${NEW_EXPIRY_DATE}"
      else
        info "No expiry header returned (classic PAT with no expiry, or token type does not expose it)."
      fi
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
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('expires_at',''))" 2>/dev/null || echo "")
      if [[ -n "$gl_expiry" ]]; then
        info "Token expiry detected: ${gl_expiry}"
        [[ -z "$NEW_EXPIRY_DATE" ]] && NEW_EXPIRY_DATE="$gl_expiry" && \
          info "Will update tracked expiry to ${NEW_EXPIRY_DATE}"
      else
        info "Could not detect GitLab token expiry."
      fi
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

  # Resolve the token with admin:org scope on OSP (App > PAT > fallback)
  OSP_TOKEN=$(resolve_osp_token)

  # GitHub org secrets API requires the public key to encrypt the value.
  # Use separate header/body files to avoid tail-1 fragility with multi-line JSON.
  _key_headers=$(mktemp)
  _key_body=$(mktemp)
  trap 'rm -f "$_key_headers" "$_key_body"' RETURN

  curl -s \
    -D "$_key_headers" \
    -o "$_key_body" \
    -H "Authorization: token ${OSP_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${OSP_ORG}/actions/secrets/public-key"

  key_http=$(head -1 "$_key_headers" | awk '{print $2}')
  key_json=$(cat "$_key_body")

  if [[ "$key_http" == "403" ]]; then
    fail "403 fetching ${OSP_ORG} public key. GitHub says: ${key_json}
  Fix options (see AGENTS.md § OSP org secret rotation):
    A) Set OSP_ADMIN_TOKEN repo secret: a PAT with admin:org on ${OSP_ORG}
    B) Set OSP_APP_ID + OSP_APP_PRIVATE_KEY: a GitHub App installed on ${OSP_ORG}
  Then re-run this workflow."
  elif [[ "$key_http" != "200" ]]; then
    fail "Unexpected HTTP ${key_http} fetching ${OSP_ORG} public key. Body: ${key_json}"
  fi

  key_id=$(echo "$key_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['key_id'])")
  pub_key=$(echo "$key_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")

  # Encrypt the secret value using libsodium (PyNaCl) — required by GitHub API.
  # Pass pub_key and token_value via environment to avoid shell interpolation issues.
  encrypted=$(PUB_KEY="$pub_key" TOKEN_VALUE="$TOKEN_VALUE" python3 - <<'PYEOF'
import base64, os
from nacl import public as nacl_public

pub_key_bytes = base64.b64decode(os.environ["PUB_KEY"])
token_bytes   = os.environ["TOKEN_VALUE"].encode()
sealed = nacl_public.SealedBox(nacl_public.PublicKey(pub_key_bytes))
print(base64.b64encode(sealed.encrypt(token_bytes)).decode())
PYEOF
  ) || fail "Encryption failed — ensure PyNaCl is installed (pip install pynacl)."

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token ${OSP_TOKEN}" \
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
    -H "Authorization: token ${OSP_TOKEN}" \
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
  # Quoted heredoc (<<'PYEOF') prevents bash from expanding ${...} inside Python code.
  # Values are passed via environment variables to avoid shell interpolation issues.
  SECRET_NAME="$SECRET_NAME" NEW_EXPIRY_DATE="$NEW_EXPIRY_DATE" \
  MONITOR_SH="$MONITOR_SH" AGENTS_MD="$AGENTS_MD" \
  python3 - <<'PYEOF'
import re, sys, os

secret  = os.environ["SECRET_NAME"]
new_exp = os.environ["NEW_EXPIRY_DATE"]
monitor = os.environ["MONITOR_SH"]
agents  = os.environ["AGENTS_MD"]

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
