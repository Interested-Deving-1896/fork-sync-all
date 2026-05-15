#!/usr/bin/env bash
#
# Syncs selected branches from kdave/btrfs-devel into
# Interested-Deving-1896/linux-merge as btrfs-devel/* refs.
#
# Uses the GitHub API exclusively — no git clone required.
# This works because kdave/btrfs-devel and linux-merge share the same fork
# network (both rooted at torvalds/linux), so GitHub's object store already
# contains every commit from btrfs-devel and refs can be created/updated
# directly via the API.
#
# Branches tracked (stable integration branches only):
#   kdave/btrfs-devel:master    → linux-merge:btrfs-devel/master
#   kdave/btrfs-devel:for-next  → linux-merge:btrfs-devel/for-next
#   kdave/btrfs-devel:misc-next → linux-merge:btrfs-devel/misc-next
#   kdave/btrfs-devel:misc-7.1  → linux-merge:btrfs-devel/misc-7.1
#
# Required env vars:
#   SYNC_TOKEN  — PAT with push access to Interested-Deving-1896/linux-merge
#
# Optional env vars:
#   DRY_RUN     — set to "true" to report without writing refs (default: false)
#   BRANCHES    — space-separated override list (default: the four above)

set -euo pipefail

: "${SYNC_TOKEN:?SYNC_TOKEN is required}"
DRY_RUN="${DRY_RUN:-false}"

UPSTREAM_REPO="kdave/btrfs-devel"
TARGET_REPO="Interested-Deving-1896/linux-merge"
PREFIX="btrfs-devel"
API="https://api.github.com"

DEFAULT_BRANCHES="master for-next misc-next misc-7.1"
read -ra BRANCHES <<< "${BRANCHES:-${DEFAULT_BRANCHES}}"

info() { echo "[sync-btrfs-devel] $*"; }
warn() { echo "[warn] $*" >&2; }

gh_api() {
  local method="$1" url="$2"; shift 2
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" -X "$method" \
    -H "Authorization: token ${SYNC_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  echo "$body"
  [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]
}

ok=0
fail=0
skipped=0
declare -a RESULTS=()

for branch in "${BRANCHES[@]}"; do
  target_ref="${PREFIX}/${branch}"
  info "── ${branch} → ${target_ref}"

  # Resolve upstream SHA
  upstream_data=$(gh_api GET "${API}/repos/${UPSTREAM_REPO}/git/ref/heads/${branch}") || {
    warn "  could not resolve ${UPSTREAM_REPO}:${branch}"
    RESULTS+=("| \`${target_ref}\` | ❌ upstream not found | — |")
    (( fail++ )) || true
    continue
  }
  upstream_sha=$(echo "$upstream_data" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['object']['sha'])" 2>/dev/null) || {
    warn "  could not parse SHA for ${branch}"
    RESULTS+=("| \`${target_ref}\` | ❌ SHA parse error | — |")
    (( fail++ )) || true
    continue
  }
  short="${upstream_sha:0:7}"
  info "  upstream SHA: ${short}"

  # Check if target ref already exists
  existing_data=$(gh_api GET "${API}/repos/${TARGET_REPO}/git/ref/heads/${target_ref}" 2>/dev/null || true)
  existing_sha=$(echo "$existing_data" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('object',{}).get('sha',''))" 2>/dev/null || true)

  if [[ "${existing_sha}" == "${upstream_sha}" ]]; then
    info "  already up to date"
    RESULTS+=("| \`${target_ref}\` | ⏭ up to date | \`${short}\` |")
    (( skipped++ )) || true
    continue
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -n "${existing_sha}" ]]; then
      info "  [dry-run] would update ${existing_sha:0:7} → ${short}"
    else
      info "  [dry-run] would create ref at ${short}"
    fi
    RESULTS+=("| \`${target_ref}\` | ⏭ dry-run | \`${short}\` |")
    (( skipped++ )) || true
    continue
  fi

  # Create or update the ref
  if [[ -n "${existing_sha}" ]]; then
    result=$(gh_api PATCH "${API}/repos/${TARGET_REPO}/git/refs/heads/${target_ref}" \
      -H "Content-Type: application/json" \
      -d "{\"sha\":\"${upstream_sha}\",\"force\":true}") || {
      warn "  PATCH failed for ${target_ref}"
      RESULTS+=("| \`${target_ref}\` | ❌ update failed | \`${short}\` |")
      (( fail++ )) || true
      continue
    }
    info "  updated ${existing_sha:0:7} → ${short}"
    RESULTS+=("| \`${target_ref}\` | ✅ updated | \`${short}\` |")
  else
    result=$(gh_api POST "${API}/repos/${TARGET_REPO}/git/refs" \
      -H "Content-Type: application/json" \
      -d "{\"ref\":\"refs/heads/${target_ref}\",\"sha\":\"${upstream_sha}\"}") || {
      warn "  POST failed for ${target_ref}"
      RESULTS+=("| \`${target_ref}\` | ❌ create failed | \`${short}\` |")
      (( fail++ )) || true
      continue
    }
    info "  created at ${short}"
    RESULTS+=("| \`${target_ref}\` | ✅ created | \`${short}\` |")
  fi
  (( ok++ )) || true
done

echo ""
echo "════════════════════════════════════════════"
echo "  sync-btrfs-devel-branches complete"
echo "  Created/updated : ${ok}"
echo "  Skipped         : ${skipped}"
echo "  Failed          : ${fail}"
echo "════════════════════════════════════════════"

STATUS_ICON="✅"
[[ "${fail}" -gt 0 ]] && STATUS_ICON="⚠️"
[[ "${DRY_RUN}" == "true" ]] && STATUS_ICON="⏭"

export SUMMARY_TITLE="Sync btrfs-devel branches ${STATUS_ICON}"
export SUMMARY_BODY="$(cat <<MDEOF
**Upstream:** \`${UPSTREAM_REPO}\` → \`${TARGET_REPO}\` (prefix: \`${PREFIX}/\`)

**Updated:** ${ok} | **Skipped:** ${skipped} | **Failed:** ${fail}
$([ "${DRY_RUN}" == "true" ] && echo "_Dry-run — no refs written._")

| Branch | Status | SHA |
|---|---|---|
$(printf '%s\n' "${RESULTS[@]}")
MDEOF
)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/write-summary.sh"

[[ "${fail}" -eq 0 ]]
