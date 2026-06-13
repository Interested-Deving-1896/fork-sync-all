#!/usr/bin/env bash
#
# refresh-notebooklm-auth.sh
#
# Rotates the short-lived __Secure-1PSIDTS cookie in the NOTEBOOKLM_AUTH_JSON
# repo secret using notebooklm auth refresh, then writes the updated state
# back to the secret via the GitHub Secrets API.
#
# This extends session life between manual re-authentications. It does NOT
# replace a full notebooklm login — if the primary SID cookie expires, a
# manual re-auth is still required.
#
# Usage:
#   bash scripts/refresh-notebooklm-auth.sh
#
# Environment (all required unless noted):
#   NOTEBOOKLM_AUTH_JSON   — current auth state JSON (from the repo secret)
#   GH_TOKEN               — PAT with secrets:write scope on this repo
#   REPO                   — target repo (default: Interested-Deving-1896/fork-sync-all)
#   DRY_RUN                — set to "true" to skip writing the secret back

set -uo pipefail

REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"

info() { echo "[refresh-notebooklm-auth] $*" >&2; }
warn() { echo "[refresh-notebooklm-auth] ⚠  $*" >&2; }
ok()   { echo "[refresh-notebooklm-auth] ✓ $*" >&2; }
fail() { echo "[refresh-notebooklm-auth] ✗ $*" >&2; }

# ── Validate env ──────────────────────────────────────────────────────────────
if [[ -z "${NOTEBOOKLM_AUTH_JSON:-}" ]]; then
  fail "NOTEBOOKLM_AUTH_JSON is not set — cannot refresh without existing auth state."
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  fail "GH_TOKEN is not set — cannot write updated secret back."
  exit 1
fi

# ── Check notebooklm-py ───────────────────────────────────────────────────────
if ! command -v notebooklm &>/dev/null; then
  fail "notebooklm CLI not found. Install with: pip install 'notebooklm-py[browser]'"
  exit 1
fi

NLM_VERSION=$(notebooklm --version 2>/dev/null || echo "unknown")
info "notebooklm-py version: ${NLM_VERSION}"

# ── Pre-refresh auth check ────────────────────────────────────────────────────
info "Checking current auth state..."
if ! notebooklm auth check --test 2>/dev/null; then
  warn "Pre-refresh auth check failed — cookies may already be expired."
  warn "A manual 'notebooklm login' and secret update may be required."
  # Continue anyway — refresh may still recover a partially-expired state.
fi

# ── Run refresh ───────────────────────────────────────────────────────────────
# notebooklm auth refresh rotates __Secure-1PSIDTS in-place and writes the
# updated state back to the NOTEBOOKLM_AUTH_JSON env var path.
# NOTEBOOKLM_AUTH_JSON is read by the library automatically — no file needed.
info "Running notebooklm auth refresh..."
if ! notebooklm auth refresh --quiet; then
  fail "notebooklm auth refresh failed."
  exit 1
fi
ok "Refresh completed."

# ── Capture updated state ─────────────────────────────────────────────────────
# After refresh, the library writes the updated cookies back to the in-memory
# state. We re-export it by reading from the default profile path that the
# library writes to when NOTEBOOKLM_AUTH_JSON is set.
#
# notebooklm-py writes the refreshed state to NOTEBOOKLM_HOME/profiles/default/
# storage_state.json when running with NOTEBOOKLM_AUTH_JSON. Fall back to that.
NLM_HOME="${NOTEBOOKLM_HOME:-${HOME}/.notebooklm}"
STATE_FILE="${NLM_HOME}/profiles/default/storage_state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  # Older layout fallback
  STATE_FILE="${HOME}/.config/notebooklm/storage_state.json"
fi

if [[ ! -f "$STATE_FILE" ]]; then
  fail "Could not locate updated storage_state.json after refresh."
  fail "Looked in: ${NLM_HOME}/profiles/default/ and ~/.config/notebooklm/"
  exit 1
fi

UPDATED_JSON=$(cat "$STATE_FILE")
if [[ -z "$UPDATED_JSON" ]]; then
  fail "Updated storage_state.json is empty."
  exit 1
fi

ok "Captured updated auth state ($(echo "$UPDATED_JSON" | wc -c) bytes)."

# ── Post-refresh auth check ───────────────────────────────────────────────────
info "Verifying refreshed auth state..."
if NOTEBOOKLM_AUTH_JSON="$UPDATED_JSON" notebooklm auth check --test 2>/dev/null; then
  ok "Post-refresh auth check passed."
else
  fail "Post-refresh auth check failed — the refreshed state is not valid."
  fail "A manual 'notebooklm login' is required. Update NOTEBOOKLM_AUTH_JSON manually."
  exit 1
fi

# ── Write updated secret ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  info "[dry-run] Would write updated NOTEBOOKLM_AUTH_JSON to ${REPO}."
  exit 0
fi

info "Writing updated NOTEBOOKLM_AUTH_JSON to ${REPO}..."
# Pipe via stdin — never passed as a shell argument.
printf '%s' "$UPDATED_JSON" \
  | gh secret set NOTEBOOKLM_AUTH_JSON --repo "$REPO" --body -

ok "NOTEBOOKLM_AUTH_JSON updated in ${REPO}."
