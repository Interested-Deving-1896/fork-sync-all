#!/usr/bin/env bash
# POST /api/fsa/bdfs/export
#
# This adapter is deliberately self-contained. The vendored UAA adapter may be
# absent while its upstream is being synchronized, but packaging must still
# fail closed and produce a verifiable artifact (or a dry-run plan).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="${GITHUB_WORKSPACE:-$(cd "${SCRIPT_DIR}/../../../.." && pwd)}"

BACKEND="${BODY_backend:-auto}"
TARGET="${BODY_target:-${REPO_PATH}/artifacts/bdfs/fsa-package}"
COMPRESSION="${BODY_compression:-zstd}"
DRY_RUN="${BODY_dry_run:-false}"

info() { echo "[bdfs-export] $*" >&2; }

emit_json() {
  python3 - "$@" <<'PYEOF'
import json, sys
keys = ("ok", "dry_run", "backend", "target", "source", "compression", "sha256", "size")
values = sys.argv[1:]
out = {}
for key, value in zip(keys, values):
    if key in {"ok", "dry_run"}:
        out[key] = value.lower() == "true"
    elif value:
        out[key] = int(value) if key == "size" else value
print(json.dumps(out, sort_keys=True))
PYEOF
}

fail() {
  local message="$1" code="${2:-1}"
  python3 - "$message" "$code" <<'PYEOF'
import json, sys
print(json.dumps({"ok": False, "error": sys.argv[1], "code": int(sys.argv[2])}, sort_keys=True))
PYEOF
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1" 5
}

case "$BACKEND" in
  auto|dwarfs|btrfs|devcontainer|incus|ostree|bootc) ;;
  *) fail "Unknown backend: ${BACKEND}" 2 ;;
esac

case "$COMPRESSION" in
  zstd|lz4|none) ;;
  *) fail "Unknown compression: ${COMPRESSION}" 2 ;;
esac

case "$DRY_RUN" in
  true|false) ;;
  *) fail "dry_run must be true or false" 2 ;;
esac

# Never allow workflow input to write outside the checked-out workspace.
workspace_real="$(realpath -m "$REPO_PATH")"
target_real="$(realpath -m "$TARGET")"
case "$target_real" in
  "$workspace_real"/*) ;;
  *) fail "Target must be inside GITHUB_WORKSPACE: ${TARGET}" 2 ;;
esac
TARGET="$target_real"

# A dry run intentionally precedes backend detection. It validates the request
# and records an auditable plan even on an ordinary GitHub-hosted runner.
if [[ "$DRY_RUN" == "true" ]]; then
  plan="${TARGET}.plan.json"
  mkdir -p "$(dirname "$plan")"
  emit_json true true "$BACKEND" "$TARGET" "$REPO_PATH" "$COMPRESSION" "" "" | tee "$plan"
  exit 0
fi

if [[ "$BACKEND" == "auto" ]]; then
  if command -v mkdwarfs >/dev/null 2>&1; then
    BACKEND="dwarfs"
  elif command -v btrfs >/dev/null 2>&1 && btrfs subvolume show "$REPO_PATH" >/dev/null 2>&1; then
    BACKEND="btrfs"
  elif command -v devcontainer >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    BACKEND="devcontainer"
  else
    fail "No verified packaging backend found (mkdwarfs, BTRFS subvolume, or devcontainer+docker)" 5
  fi
fi

mkdir -p "$(dirname "$TARGET")"
artifact=""

case "$BACKEND" in
  dwarfs)
    require_cmd mkdwarfs
    artifact="${TARGET}.dwarfs"
    info "Creating DwarFS artifact: $artifact"
    args=(-i "$REPO_PATH" -o "$artifact" --compression "$COMPRESSION")
    mkdwarfs "${args[@]}" >&2
    ;;

  btrfs)
    require_cmd btrfs
    require_cmd zstd
    btrfs subvolume show "$REPO_PATH" >/dev/null 2>&1 || \
      fail "BTRFS export requires GITHUB_WORKSPACE to be a BTRFS subvolume" 3
    snapshot="$(dirname "$REPO_PATH")/.fsa-bdfs-export-${GITHUB_RUN_ID:-$$}"
    [[ ! -e "$snapshot" ]] || fail "Temporary snapshot already exists: $snapshot" 3
    cleanup_snapshot() {
      [[ -d "$snapshot" ]] && btrfs subvolume delete "$snapshot" >/dev/null 2>&1 || true
    }
    trap cleanup_snapshot EXIT
    btrfs subvolume snapshot -r "$REPO_PATH" "$snapshot" >&2
    artifact="${TARGET}.btrfs.zst"
    info "Creating BTRFS send-stream artifact: $artifact"
    btrfs send "$snapshot" | zstd -T0 -o "$artifact"
    cleanup_snapshot
    trap - EXIT
    ;;

  devcontainer)
    require_cmd devcontainer
    require_cmd docker
    image="fsa-bdfs:${GITHUB_SHA:-local}"
    info "Building devcontainer image: $image"
    devcontainer build --workspace-folder "$REPO_PATH" --image-name "$image" >&2
    artifact="${TARGET}.oci.tar"
    docker image inspect "$image" >/dev/null
    docker save --output "$artifact" "$image"
    ;;

  incus|ostree|bootc)
    fail "Backend '${BACKEND}' does not yet have a verified single-file artifact contract" 3
    ;;
esac

[[ -n "$artifact" && -s "$artifact" ]] || fail "Backend '${BACKEND}' did not produce a non-empty artifact" 3
sha256="$(sha256sum "$artifact" | awk '{print $1}')"
size="$(stat -c %s "$artifact")"
printf '%s  %s\n' "$sha256" "$(basename "$artifact")" > "${artifact}.sha256"
emit_json true false "$BACKEND" "$artifact" "$REPO_PATH" "$COMPRESSION" "$sha256" "$size"
