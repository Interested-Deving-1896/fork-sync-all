#!/usr/bin/env bash
# POST /api/fsa/bdfs/import
# Imports a bdfs workspace/image into the local environment.
# Agnostic across all bdfs integration backends.
#
# Body (JSON):
#   {
#     "source":  "path or image reference to import from",
#     "backend": "dwarfs|btrfs|ostree|bootc|incus|devcontainer|auto",
#     "mount":   "/mnt/fsa-import"  (optional mountpoint),
#     "dry_run": false
#   }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

SOURCE="${BODY_source:-}"
BACKEND="${BODY_backend:-auto}"
MOUNT="${BODY_mount:-/mnt/fsa-import}"
DRY_RUN="${BODY_dry_run:-false}"

[[ -z "$SOURCE" ]] && { fsa_error "Missing required field: source" 400; exit 0; }

# Auto-detect backend from source path/extension
if [[ "$BACKEND" == "auto" ]]; then
  if [[ "$SOURCE" == *.dwarfs ]]; then
    BACKEND="dwarfs"
  elif [[ "$SOURCE" == *.tar* || "$SOURCE" == *.oci* ]]; then
    BACKEND="devcontainer"
  elif [[ "$SOURCE" == ostree:* ]]; then
    BACKEND="ostree"
  elif command -v bdfs &>/dev/null; then
    BACKEND="dwarfs"
  else
    BACKEND="devcontainer"
  fi
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "{\"ok\":true,\"dry_run\":true,\"backend\":\"${BACKEND}\",\"source\":\"${SOURCE}\",\"mount\":\"${MOUNT}\"}"
  exit 0
fi

case "$BACKEND" in
  dwarfs|btrfs)
    if ! command -v bdfs &>/dev/null; then
      fsa_error "bdfs not installed" 503; exit 0
    fi
    result=$(bdfs import \
      --image "$SOURCE" \
      --btrfs-mount "$MOUNT" \
      --subvol-name "fsa-import-$(date +%Y%m%d)" 2>&1 || echo "ERROR: $?")
    ;;
  devcontainer)
    if command -v bdfs-devcontainer &>/dev/null; then
      result=$(bdfs-devcontainer import --source "$SOURCE" --workspace "$MOUNT" 2>&1 || echo "ERROR: $?")
    else
      result=$(devcontainer up --workspace-folder "$MOUNT" 2>&1 || echo "ERROR: $?")
    fi
    ;;
  incus)
    if command -v bdfs-incusos &>/dev/null; then
      result=$(bdfs-incusos import --source "$SOURCE" --name "fsa-import" 2>&1 || echo "ERROR: $?")
    else
      result=$(incus image import "$SOURCE" 2>&1 || echo "ERROR: $?")
    fi
    ;;
  ostree)
    if command -v bdfs-ostree &>/dev/null; then
      result=$(bdfs-ostree deploy --source "$SOURCE" --mount "$MOUNT" 2>&1 || echo "ERROR: $?")
    else
      result=$(ostree checkout --repo="$SOURCE" fork-sync-all "$MOUNT" 2>&1 || echo "ERROR: $?")
    fi
    ;;
  bootc)
    if command -v bdfs-bootc &>/dev/null; then
      result=$(bdfs-bootc import --source "$SOURCE" --mount "$MOUNT" 2>&1 || echo "ERROR: $?")
    else
      fsa_error "bdfs-bootc integration required for bootc backend" 503; exit 0
    fi
    ;;
  *)
    fsa_error "Unknown backend: ${BACKEND}" 400; exit 0
    ;;
esac

if echo "$result" | grep -qi "^ERROR:"; then
  fsa_error "Import failed (${BACKEND}): ${result}" 500
else
  echo "{\"ok\":true,\"backend\":\"${BACKEND}\",\"source\":\"${SOURCE}\",\"mount\":\"${MOUNT}\"}"
fi
