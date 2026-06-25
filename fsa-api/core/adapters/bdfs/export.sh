#!/usr/bin/env bash
# POST /api/fsa/bdfs/export
# Exports fork-sync-all (or a consumer repo) as a bdfs workspace.
# Delegates to the appropriate integration backend based on availability
# and the requested target format.
#
# Body (JSON):
#   {
#     "backend":     "dwarfs|btrfs|ostree|bootc|incus|devcontainer|auto",
#     "target":      "path or image name for the export",
#     "compression": "zstd|lz4|none"  (default: zstd, dwarfs only),
#     "dry_run":     false
#   }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

BACKEND="${BODY_backend:-auto}"
TARGET="${BODY_target:-}"
COMPRESSION="${BODY_compression:-zstd}"
DRY_RUN="${BODY_dry_run:-false}"

REPO_PATH="${_FSA_ROOT}"

# ── Auto-detect best available backend ───────────────────────────────────────
if [[ "$BACKEND" == "auto" ]]; then
  if command -v bdfs &>/dev/null; then
    BACKEND="dwarfs"
  elif command -v devcontainer &>/dev/null; then
    BACKEND="devcontainer"
  elif command -v incus &>/dev/null; then
    BACKEND="incus"
  elif command -v ostree &>/dev/null; then
    BACKEND="ostree"
  else
    fsa_error "No bdfs-compatible backend found. Install bdfs, devcontainer, incus, or ostree." 503
    exit 0
  fi
fi

[[ -z "$TARGET" ]] && TARGET="/tmp/fsa-export-$(date +%Y%m%d-%H%M%S)"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "{\"ok\":true,\"dry_run\":true,\"backend\":\"${BACKEND}\",\"target\":\"${TARGET}\",\"source\":\"${REPO_PATH}\"}"
  exit 0
fi

# ── Backend dispatch ──────────────────────────────────────────────────────────
case "$BACKEND" in
  dwarfs|btrfs)
    if ! command -v bdfs &>/dev/null; then
      fsa_error "bdfs not installed — cannot use backend: ${BACKEND}" 503
      exit 0
    fi
    result=$(bdfs export \
      --btrfs-mount "$REPO_PATH" \
      --name "$(basename "$TARGET")" \
      --compression "$COMPRESSION" \
      --verify 2>&1 || echo "ERROR: $?")
    ;;

  devcontainer)
    if ! command -v devcontainer &>/dev/null; then
      fsa_error "devcontainer CLI not installed" 503
      exit 0
    fi
    # Use bdfs-devcontainer integration if available
    if command -v bdfs-devcontainer &>/dev/null; then
      result=$(bdfs-devcontainer export --workspace "$REPO_PATH" --output "$TARGET" 2>&1 || echo "ERROR: $?")
    else
      result=$(devcontainer build --workspace-folder "$REPO_PATH" --image-name "$TARGET" 2>&1 || echo "ERROR: $?")
    fi
    ;;

  incus)
    if ! command -v incus &>/dev/null; then
      fsa_error "incus not installed" 503
      exit 0
    fi
    if command -v bdfs-incusos &>/dev/null; then
      result=$(bdfs-incusos export --workspace "$REPO_PATH" --output "$TARGET" 2>&1 || echo "ERROR: $?")
    else
      result=$(incus export "$TARGET" "$REPO_PATH" 2>&1 || echo "ERROR: $?")
    fi
    ;;

  ostree)
    if ! command -v ostree &>/dev/null; then
      fsa_error "ostree not installed" 503
      exit 0
    fi
    if command -v bdfs-ostree &>/dev/null; then
      result=$(bdfs-ostree commit --workspace "$REPO_PATH" --repo "$TARGET" 2>&1 || echo "ERROR: $?")
    else
      result=$(ostree commit --repo="$TARGET" --branch=fork-sync-all "$REPO_PATH" 2>&1 || echo "ERROR: $?")
    fi
    ;;

  bootc)
    if ! command -v bootc &>/dev/null; then
      fsa_error "bootc not installed" 503
      exit 0
    fi
    if command -v bdfs-bootc &>/dev/null; then
      result=$(bdfs-bootc export --workspace "$REPO_PATH" --output "$TARGET" 2>&1 || echo "ERROR: $?")
    else
      fsa_error "bdfs-bootc integration required for bootc backend" 503
      exit 0
    fi
    ;;

  *)
    fsa_error "Unknown backend: ${BACKEND}. Valid: auto|dwarfs|btrfs|devcontainer|incus|ostree|bootc" 400
    exit 0
    ;;
esac

# ── Result ────────────────────────────────────────────────────────────────────
if echo "$result" | grep -qi "^ERROR:"; then
  fsa_error "Export failed (${BACKEND}): ${result}" 500
else
  echo "{\"ok\":true,\"backend\":\"${BACKEND}\",\"target\":\"${TARGET}\",\"compression\":\"${COMPRESSION}\",\"source\":\"${REPO_PATH}\"}"
fi
