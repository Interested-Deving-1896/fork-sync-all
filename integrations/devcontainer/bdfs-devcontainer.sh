#!/usr/bin/env bash
# bdfs-devcontainer — Dev Container integration for btrfs-dwarfs-framework
#
# Bridges the Dev Container spec (https://containers.dev) with bdfs's
# snapshot and workspace capabilities. Provides helpers for:
#
#   snapshot    Snapshot a running dev container's filesystem into a bdfs workspace
#   export      Export a dev container image or workspace as a DwarFS archive
#   import      Import a DwarFS archive as a container image usable by devcontainer up
#   build       Build a dev container image and optionally pack it as DwarFS
#   up          Wrap `devcontainer up` with a pre-snapshot of the workspace root
#   status      Show running dev containers and any bdfs workspaces derived from them
#
# Environment:
#   BDFS_DC_WORKSPACE_FOLDER   Default --workspace-folder path
#   BDFS_DC_IMAGE_STORE        Directory for exported DwarFS images
#
# Dependencies: devcontainer CLI, docker or podman, bdfs, mkdwarfs/dwarfs
#
# Usage:
#   bdfs-devcontainer.sh snapshot [--container ID|NAME] [--name WORKSPACE]
#   bdfs-devcontainer.sh export   [--container ID|NAME] --out PATH [--compression zstd]
#   bdfs-devcontainer.sh import   <image-path> --tag IMAGE[:TAG]
#   bdfs-devcontainer.sh build    [--workspace-folder PATH] [--pack --out PATH]
#   bdfs-devcontainer.sh up       [--workspace-folder PATH] [--snapshot]
#   bdfs-devcontainer.sh status

set -euo pipefail

BDFS_CMD="${BDFS_CMD:-bdfs}"
DC_CMD="${DC_CMD:-devcontainer}"
DOCKER_CMD="${DOCKER_CMD:-docker}"

BDFS_DC_WORKSPACE_FOLDER="${BDFS_DC_WORKSPACE_FOLDER:-$PWD}"
BDFS_DC_IMAGE_STORE="${BDFS_DC_IMAGE_STORE:-/var/lib/bdfs/devcontainer-images}"

# ── Helpers ───────────────────────────────────────────────────────────────────

info() { echo "[bdfs-devcontainer] $*"; }
die()  { echo "[bdfs-devcontainer] ERROR: $*" >&2; exit "${2:-1}"; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found — install $2"
}

require_bdfs()        { require_cmd bdfs        "btrfs-dwarfs-framework"; }
require_devcontainer(){ require_cmd devcontainer "devcontainer CLI (https://github.com/devcontainers/cli)"; }
require_docker()      {
    command -v docker  &>/dev/null && DOCKER_CMD=docker  && return
    command -v podman  &>/dev/null && DOCKER_CMD=podman  && return
    die "docker or podman required"
}

container_rootfs() {
    # Returns the merged/overlay rootfs path for a running container.
    local id="$1"
    $DOCKER_CMD inspect --format '{{.GraphDriver.Data.MergedDir}}' "$id" 2>/dev/null \
        || $DOCKER_CMD inspect --format '{{.GraphDriver.Data.UpperDir}}' "$id" 2>/dev/null \
        || die "Cannot determine rootfs for container '$id' — is it running?"
}

# ── snapshot ──────────────────────────────────────────────────────────────────

cmd_snapshot() {
    local container="" name="devcontainer-snapshot-$(date +%Y%m%d-%H%M%S)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container) container="$2"; shift 2 ;;
            --name)      name="$2";      shift 2 ;;
            -*)          die "Unknown option: $1" ;;
            *)           die "Unexpected argument: $1" ;;
        esac
    done

    require_bdfs
    require_docker

    if [[ -z "$container" ]]; then
        # Auto-detect: find the most recently started devcontainer
        container="$($DOCKER_CMD ps --filter "label=devcontainer.local_folder" \
            --format "{{.ID}}" | head -1)"
        [[ -n "$container" ]] || die "No running dev container found — use --container ID"
        info "Auto-detected container: $container"
    fi

    local rootfs
    rootfs="$(container_rootfs "$container")"

    info "Snapshotting container '$container' rootfs → bdfs workspace '$name'"
    $BDFS_CMD dev create "$name" --source "$rootfs"
    info "Snapshot ready. Enter with: bdfs dev shell $name"
}

# ── export ────────────────────────────────────────────────────────────────────

cmd_export() {
    local container="" out="" compression="zstd"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container)   container="$2";   shift 2 ;;
            --out)         out="$2";         shift 2 ;;
            --compression) compression="$2"; shift 2 ;;
            -*)            die "Unknown option: $1" ;;
            *)             die "Unexpected argument: $1" ;;
        esac
    done
    [[ -n "$out" ]] || die "--out PATH required"

    require_docker
    require_cmd mkdwarfs "dwarfs (mkdwarfs)"

    local tmpdir
    tmpdir="$(mktemp -d /tmp/bdfs-devcontainer-export.XXXXXX)"
    trap "rm -rf '$tmpdir'" EXIT

    if [[ -n "$container" ]]; then
        # Export from a running container's rootfs
        local rootfs
        rootfs="$(container_rootfs "$container")"
        info "Exporting container '$container' rootfs → DwarFS: $out"
        mkdwarfs -i "$rootfs" -o "$out" --compression "$compression" \
            --exclude-caches \
            --filter "- /proc/**" \
            --filter "- /sys/**" \
            --filter "- /dev/**" \
            --filter "- /run/**" \
            --filter "- /tmp/**"
    else
        die "--container ID required for export"
    fi

    mkdir -p "$(dirname "$out")"
    info "Exported: $out ($(du -sh "$out" | cut -f1))"
}

# ── import ────────────────────────────────────────────────────────────────────

cmd_import() {
    local image="" tag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) tag="$2"; shift 2 ;;
            -*)    die "Unknown option: $1" ;;
            *)     image="$1"; shift ;;
        esac
    done
    [[ -n "$image" ]] || die "Usage: bdfs-devcontainer import <image-path> --tag IMAGE[:TAG]"
    [[ -f "$image" ]] || die "Image not found: $image"
    [[ -n "$tag"   ]] || die "--tag IMAGE[:TAG] required"

    require_docker
    require_cmd dwarfs "dwarfs"

    local tmpdir mp
    tmpdir="$(mktemp -d /tmp/bdfs-devcontainer-import.XXXXXX)"
    mp="$tmpdir/mount"
    mkdir -p "$mp"
    trap "fusermount -u '$mp' 2>/dev/null; rm -rf '$tmpdir'" EXIT

    info "Mounting DwarFS image: $image"
    dwarfs "$image" "$mp"

    info "Importing as container image: $tag"
    tar -C "$mp" -c . | $DOCKER_CMD import - "$tag"
    info "Imported. Use in devcontainer.json: \"image\": \"$tag\""
}

# ── build ─────────────────────────────────────────────────────────────────────

cmd_build() {
    local workspace="" pack=false out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace-folder) workspace="$2"; shift 2 ;;
            --pack)             pack=true;      shift ;;
            --out)              out="$2";       shift 2 ;;
            -*)                 die "Unknown option: $1" ;;
            *)                  die "Unexpected argument: $1" ;;
        esac
    done
    workspace="${workspace:-$BDFS_DC_WORKSPACE_FOLDER}"

    require_devcontainer
    require_docker

    info "Building dev container for: $workspace"
    local image_id
    image_id="$($DC_CMD build --workspace-folder "$workspace" --output '{"type":"image"}' \
        2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('imageName',''))" \
        2>/dev/null || true)"

    $DC_CMD build --workspace-folder "$workspace"

    if $pack; then
        [[ -n "$out" ]] || die "--out PATH required with --pack"
        require_cmd mkdwarfs "dwarfs (mkdwarfs)"
        local tmpdir
        tmpdir="$(mktemp -d /tmp/bdfs-devcontainer-build.XXXXXX)"
        trap "rm -rf '$tmpdir'" EXIT
        info "Exporting built image to DwarFS: $out"
        # Save image as tar, extract, pack with mkdwarfs
        $DOCKER_CMD save "${image_id:-devcontainer}" | tar -x -C "$tmpdir" 2>/dev/null || true
        mkdwarfs -i "$tmpdir" -o "$out" --compression zstd
        info "Packed: $out ($(du -sh "$out" | cut -f1))"
    fi
}

# ── up ────────────────────────────────────────────────────────────────────────

cmd_up() {
    local workspace="" snapshot=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workspace-folder) workspace="$2"; shift 2 ;;
            --snapshot)         snapshot=true;  shift ;;
            -*)                 die "Unknown option: $1" ;;
            *)                  die "Unexpected argument: $1" ;;
        esac
    done
    workspace="${workspace:-$BDFS_DC_WORKSPACE_FOLDER}"

    require_devcontainer

    if $snapshot; then
        require_bdfs
        local snap_name="pre-up-$(basename "$workspace")-$(date +%Y%m%d-%H%M%S)"
        info "Pre-snapshot of workspace root → bdfs workspace '$snap_name'"
        $BDFS_CMD dev create "$snap_name" --source "$workspace"
        info "Snapshot saved. Continuing with devcontainer up..."
    fi

    info "Starting dev container for: $workspace"
    $DC_CMD up --workspace-folder "$workspace"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    require_docker

    echo "=== Running dev containers ==="
    $DOCKER_CMD ps --filter "label=devcontainer.local_folder" \
        --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Label \"devcontainer.local_folder\"}}" \
        2>/dev/null || $DOCKER_CMD ps 2>/dev/null | head -10

    echo ""
    echo "=== bdfs workspaces ==="
    $BDFS_CMD dev list 2>/dev/null || echo "(no bdfs workspaces)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
    snapshot) cmd_snapshot "$@" ;;
    export)   cmd_export   "$@" ;;
    import)   cmd_import   "$@" ;;
    build)    cmd_build    "$@" ;;
    up)       cmd_up       "$@" ;;
    status)   cmd_status   "$@" ;;
    ""|help)
        echo "Usage: bdfs-devcontainer <subcommand> [options]"
        echo ""
        echo "Subcommands:"
        echo "  snapshot  Snapshot a running dev container into a bdfs workspace"
        echo "  export    Export a dev container rootfs as a DwarFS archive"
        echo "  import    Import a DwarFS archive as a container image"
        echo "  build     Build a dev container image [--pack --out PATH]"
        echo "  up        Start a dev container [--snapshot] [--workspace-folder PATH]"
        echo "  status    Show running dev containers and bdfs workspaces"
        ;;
    *) die "Unknown subcommand: $SUBCOMMAND (run bdfs-devcontainer help)" ;;
esac
