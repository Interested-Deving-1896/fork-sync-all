#!/usr/bin/env bash
#
# scripts/includes/fsa-mode.sh — fork-sync-all managed vs. autonomous mode detection
#
# Determines whether this repo is being managed centrally by a fork-sync-all
# instance (managed mode) or is running independently without one (autonomous
# mode). Consumer repos bundle operational workflows (rate-limit rerun, CI
# resolver, queue manager, etc.) as fallbacks; those workflows source this
# helper and exit early when fork-sync-all is already handling things.
#
# Detection order (hybrid A+B+C):
#
#   1. Repo variable FSA_MANAGED=true  (B — cheapest, no API call)
#      Set automatically by fork-sync-all's sync-template.sh on every push.
#      If present and "true", we are in managed mode.
#
#   2. fork-sync-all repo exists under the same owner  (A)
#      GET /repos/{github.repository_owner}/fork-sync-all — if 200, managed.
#      Handles the case where FSA_MANAGED was never set (e.g. first sync).
#
#   3. SYNC_TOKEN resolves to a user that owns fork-sync-all  (C — tiebreaker)
#      If the token's authenticated user has a fork-sync-all repo, managed.
#      Handles forks where the owner slug differs from the token owner.
#
# Usage (in a workflow run: block):
#
#   source scripts/includes/fsa-mode.sh
#   if fsa_is_managed; then
#     echo "Managed by fork-sync-all — skipping autonomous fallback"
#     exit 0
#   fi
#   # ... autonomous logic ...
#
# Usage (in a workflow step with outputs):
#
#   - name: Check FSA mode
#     id: fsa
#     env:
#       GH_TOKEN: ${{ secrets.SYNC_TOKEN }}
#       FSA_MANAGED: ${{ vars.FSA_MANAGED }}
#       REPO_OWNER: ${{ github.repository_owner }}
#     run: |
#       source scripts/includes/fsa-mode.sh
#       if fsa_is_managed; then
#         echo "managed=true" >> "$GITHUB_OUTPUT"
#       else
#         echo "managed=false" >> "$GITHUB_OUTPUT"
#       fi
#
# Environment variables read:
#   FSA_MANAGED   — repo variable (set by sync-template.sh). "true" = managed.
#   GH_TOKEN      — PAT used for API checks (B and C). Optional: if absent,
#                   only the FSA_MANAGED variable check (A) is performed.
#   REPO_OWNER    — GitHub org/user that owns this repo. Defaults to the value
#                   of GITHUB_REPOSITORY_OWNER (set by GitHub Actions).
#
# Guard against double-sourcing
[[ -n "${_FSA_MODE_LOADED:-}" ]] && return 0
_FSA_MODE_LOADED=1

_fsa_api="https://api.github.com"

# _fsa_get: silent GET, returns body on 2xx, empty string otherwise.
_fsa_get() {
  local url="$1"
  local token="${GH_TOKEN:-}"
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: token ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" =~ ^2 ]]; then
    echo "$body"
  fi
}

# fsa_is_managed: returns 0 (true) if this repo is in managed mode.
fsa_is_managed() {
  local owner="${REPO_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"

  # ── Check B: repo variable FSA_MANAGED ──────────────────────────────────
  local var_val="${FSA_MANAGED:-}"
  if [[ "$var_val" == "true" ]]; then
    echo "[fsa-mode] FSA_MANAGED=true — managed mode" >&2
    return 0
  fi

  # Skip API checks if no token available
  local token="${GH_TOKEN:-}"
  if [[ -z "$token" ]]; then
    echo "[fsa-mode] No GH_TOKEN — assuming autonomous mode" >&2
    return 1
  fi

  # ── Check A: fork-sync-all exists under same owner ───────────────────────
  if [[ -n "$owner" ]]; then
    local body
    body=$(_fsa_get "${_fsa_api}/repos/${owner}/fork-sync-all")
    if [[ -n "$body" ]]; then
      echo "[fsa-mode] ${owner}/fork-sync-all exists — managed mode" >&2
      return 0
    fi
  fi

  # ── Check C: token owner has fork-sync-all ───────────────────────────────
  local token_owner
  token_owner=$(_fsa_get "${_fsa_api}/user" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)
  if [[ -n "$token_owner" && "$token_owner" != "$owner" ]]; then
    local body2
    body2=$(_fsa_get "${_fsa_api}/repos/${token_owner}/fork-sync-all")
    if [[ -n "$body2" ]]; then
      echo "[fsa-mode] ${token_owner}/fork-sync-all exists (token owner) — managed mode" >&2
      return 0
    fi
  fi

  echo "[fsa-mode] No fork-sync-all found — autonomous mode" >&2
  return 1
}

# fsa_should_run_control_plane: true for the canonical fork-sync-all control
# plane and for autonomous downstream repositories. Managed consumer repos
# return false because the canonical instance provides these fallback services.
fsa_should_run_control_plane() {
  local canonical_owner="${FSA_CANONICAL_OWNER:-Interested-Deving-1896}"
  local repository="${GITHUB_REPOSITORY:-}"

  if [[ "$repository" == "${canonical_owner}/fork-sync-all" ]]; then
    echo "[fsa-mode] Canonical control plane — central fallback services enabled" >&2
    return 0
  fi
  if fsa_is_managed; then
    echo "[fsa-mode] Managed consumer — central fallback services disabled" >&2
    return 1
  fi
  echo "[fsa-mode] Autonomous repository — local fallback services enabled" >&2
  return 0
}
