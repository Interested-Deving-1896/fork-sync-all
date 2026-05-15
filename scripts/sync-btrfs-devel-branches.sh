#!/usr/bin/env bash
#
# Fetches selected integration branches from kdave/btrfs-devel and pushes
# them to Interested-Deving-1896/linux-merge with a btrfs-devel/ prefix.
#
# kdave/btrfs-devel is a fork of torvalds/linux. GitHub only allows one fork
# of a root repo per account, so linux-merge (also rooted at torvalds/linux)
# is the correct home for these branches.
#
# Branches tracked (stable integration branches only — not dev/wip/fix):
#   kdave/btrfs-devel:master    → linux-merge:btrfs-devel/master
#   kdave/btrfs-devel:for-next  → linux-merge:btrfs-devel/for-next
#   kdave/btrfs-devel:misc-next → linux-merge:btrfs-devel/misc-next
#   kdave/btrfs-devel:misc-7.1  → linux-merge:btrfs-devel/misc-7.1
#
# Required env vars:
#   SYNC_TOKEN  — PAT with push access to Interested-Deving-1896/linux-merge
#
# Optional env vars:
#   DRY_RUN     — set to "true" to fetch but skip push (default: false)
#   BRANCHES    — space-separated override list (default: the four above)

set -euo pipefail

: "${SYNC_TOKEN:?SYNC_TOKEN is required}"
DRY_RUN="${DRY_RUN:-false}"

UPSTREAM="https://github.com/kdave/btrfs-devel.git"
TARGET="https://x-access-token:${SYNC_TOKEN}@github.com/Interested-Deving-1896/linux-merge.git"
TARGET_DISPLAY="https://github.com/Interested-Deving-1896/linux-merge"
PREFIX="btrfs-devel"

DEFAULT_BRANCHES="master for-next misc-next misc-7.1"
read -ra BRANCHES <<< "${BRANCHES:-${DEFAULT_BRANCHES}}"

info()  { echo "[sync-btrfs-devel] $*"; }
warn()  { echo "[warn] $*" >&2; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

info "Cloning linux-merge (bare)..."
git clone --bare "${TARGET}" "${WORK_DIR}/linux-merge.git" 2>&1
cd "${WORK_DIR}/linux-merge.git"

info "Fetching branches from kdave/btrfs-devel..."
git fetch "${UPSTREAM}" "${BRANCHES[@]}" 2>&1

ok=0
fail=0
skipped=0
declare -a RESULTS=()

for branch in "${BRANCHES[@]}"; do
  target_branch="${PREFIX}/${branch}"
  info "── ${branch} → ${target_branch}"

  # Get the fetched SHA
  fetched_sha=$(git rev-parse FETCH_HEAD 2>/dev/null || true)
  # Re-fetch individually to get per-branch SHA
  git fetch "${UPSTREAM}" "${branch}" 2>/dev/null
  fetched_sha=$(git rev-parse FETCH_HEAD)
  short_sha="${fetched_sha:0:7}"

  # Check if target branch already exists and is up to date
  existing_sha=$(git rev-parse "refs/heads/${target_branch}" 2>/dev/null || true)
  if [[ "${existing_sha}" == "${fetched_sha}" ]]; then
    info "  already up to date (${short_sha})"
    RESULTS+=("| \`${target_branch}\` | ⏭ up to date | \`${short_sha}\` |")
    (( skipped++ )) || true
    continue
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "  [dry-run] would push ${short_sha} → ${TARGET_DISPLAY}:${target_branch}"
    RESULTS+=("| \`${target_branch}\` | ⏭ dry-run | \`${short_sha}\` |")
    (( skipped++ )) || true
    continue
  fi

  # Update the ref locally then push
  git update-ref "refs/heads/${target_branch}" "${fetched_sha}"
  if git push origin "refs/heads/${target_branch}:refs/heads/${target_branch}" --force 2>&1; then
    info "  pushed ${short_sha}"
    RESULTS+=("| \`${target_branch}\` | ✅ pushed | \`${short_sha}\` |")
    (( ok++ )) || true
  else
    warn "  push failed for ${target_branch}"
    RESULTS+=("| \`${target_branch}\` | ❌ push failed | \`${short_sha}\` |")
    (( fail++ )) || true
  fi
done

echo ""
echo "════════════════════════════════════════════"
echo "  sync-btrfs-devel-branches complete"
echo "  Pushed  : ${ok}"
echo "  Skipped : ${skipped}"
echo "  Failed  : ${fail}"
echo "════════════════════════════════════════════"

# Write job summary
STATUS_ICON="✅"
[[ "${fail}" -gt 0 ]] && STATUS_ICON="⚠️"
[[ "${DRY_RUN}" == "true" ]] && STATUS_ICON="⏭"

export SUMMARY_TITLE="Sync btrfs-devel branches ${STATUS_ICON}"
export SUMMARY_BODY="$(cat <<MDEOF
**Upstream:** \`kdave/btrfs-devel\` → \`Interested-Deving-1896/linux-merge\` (prefix: \`${PREFIX}/\`)

**Pushed:** ${ok} | **Skipped:** ${skipped} | **Failed:** ${fail}
$([ "${DRY_RUN}" == "true" ] && echo "_Dry-run — no pushes performed._")

| Branch | Status | SHA |
|---|---|---|
$(printf '%s\n' "${RESULTS[@]}")
MDEOF
)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/write-summary.sh"

[[ "${fail}" -eq 0 ]]
