#!/usr/bin/env bash
# bdfs-bootc — bootc integration for btrfs-dwarfs-framework
#
# Bridges bootc's OCI-container-as-OS model with bdfs's snapshot and
# workspace capabilities. Provides helpers for:
#
#   workspace   Create a bdfs workspace from the active bootc image root
#   commit      Pack a bdfs workspace into an OCI image layer and push
#   switch      Switch the booted image (wraps bootc switch)
#   upgrade     Upgrade in place (wraps bootc upgrade)
#   export      Export the active bootc root as a DwarFS image
#   status      Show bootc status + any active bdfs workspaces on it
#
# Environment:
#   BDFS_BOOTC_IMAGE    Default OCI image reference (overridden by --image)
#   BDFS_BOOTC_REGISTRY Default registry prefix for push operations
#
# Dependencies: bootc, bdfs, skopeo or podman (for commit/push)
#
# Usage:
#   bdfs-bootc.sh workspace [--source PATH] [--name NAME]
#   bdfs-bootc.sh commit    <workspace-name> --image IMAGE [--push]
#   bdfs-bootc.sh switch    --image IMAGE
#   bdfs-bootc.sh upgrade   [--check]
#   bdfs-bootc.sh export    [--source PATH] --out PATH [--compression zstd]
#   bdfs-bootc.sh status

set -euo pipefail

BDFS_CMD="${BDFS_CMD:-bdfs}"
BOOTC_CMD="${BOOTC_CMD:-bootc}"
PODMAN_CMD="${PODMAN_CMD:-podman}"

BDFS_BOOTC_IMAGE="${BDFS_BOOTC_IMAGE:-}"
BDFS_BOOTC_REGISTRY="${BDFS_BOOTC_REGISTRY:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────

info() { echo "[bdfs-bootc] $*"; }
die()  { echo "[bdfs-bootc] ERROR: $*" >&2; exit "${2:-1}"; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found — install $2"
}

require_bootc() { require_cmd bootc "bootc (https://github.com/bootc-dev/bootc)"; }
require_bdfs()  { require_cmd bdfs  "btrfs-dwarfs-framework"; }

active_bootc_root() {
    # Returns the path to the active bootc deployment root.
    # bootc uses OSTree under the hood; the active root is /
    # but for snapshot purposes we want the ostree deployment path.
    local deploy
    deploy="$(bootc status --json 2>/dev/null | \
        python3 -c "import json,sys; s=json.load(sys.stdin); \
        print(s.get('status',{}).get('booted',{}).get('image',{}).get('image',{}).get('image',''))" \
        2>/dev/null || true)"
    # Fall back to / if we can't determine the deployment path
    echo "${deploy:-/}"
}

workspace_mountpoint() {
    local name="$1"
    local mp
    mp="$($BDFS_CMD dev status "$name" 2>/dev/null | awk '/mountpoint:/{print $2}')"
    [[ -n "$mp" ]] || die "workspace '$name' is not mounted (run: bdfs dev shell $name)"
    echo "$mp"
}

# ── workspace ─────────────────────────────────────────────────────────────────

cmd_workspace() {
    local source="" name="bootc-workspace-$(date +%Y%m%d-%H%M%S)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            --name)   name="$2";   shift 2 ;;
            -*)       die "Unknown option: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    require_bootc
    require_bdfs

    source="${source:-$(active_bootc_root)}"
    [[ -n "$source" ]] || die "Could not determine bootc root — use --source PATH"

    info "Creating bdfs workspace '$name' from bootc root: $source"
    $BDFS_CMD dev create "$name" --source "$source"
    info "Workspace ready. Enter with: bdfs dev shell $name"
    info "Commit back with: bdfs-bootc commit $name --image <registry/image:tag> --push"
}

# ── commit ────────────────────────────────────────────────────────────────────

cmd_commit() {
    local name="" image="" push=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image) image="$2"; shift 2 ;;
            --push)  push=true;  shift ;;
            -*)      die "Unknown option: $1" ;;
            *)       name="$1";  shift ;;
        esac
    done
    [[ -n "$name"  ]] || die "Usage: bdfs-bootc commit <workspace-name> --image IMAGE [--push]"
    [[ -n "$image" ]] || die "--image IMAGE required (e.g. quay.io/myorg/myos:dev)"

    require_bdfs
    require_cmd podman "podman or skopeo"

    local mp
    mp="$(workspace_mountpoint "$name")"

    info "Building OCI image from workspace '$name' ($mp)"
    # Create a minimal Containerfile that uses the workspace root as the base
    local tmpdir
    tmpdir="$(mktemp -d /tmp/bdfs-bootc-commit.XXXXXX)"
    trap "rm -rf '$tmpdir'" EXIT

    cat > "$tmpdir/Containerfile" <<EOF
FROM scratch
COPY . /
LABEL org.opencontainers.image.description="bdfs-bootc commit from workspace $name"
EOF

    $PODMAN_CMD build \
        --file "$tmpdir/Containerfile" \
        --tag "$image" \
        "$mp"

    if $push; then
        info "Pushing $image"
        $PODMAN_CMD push "$image"
        info "Pushed. Switch with: bdfs-bootc switch --image $image"
    else
        info "Built $image (local). Use --push to push, or: podman push $image"
    fi
}

# ── switch ────────────────────────────────────────────────────────────────────

cmd_switch() {
    local image=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image) image="$2"; shift 2 ;;
            -*)      die "Unknown option: $1" ;;
            *)       die "Unexpected argument: $1" ;;
        esac
    done
    image="${image:-$BDFS_BOOTC_IMAGE}"
    [[ -n "$image" ]] || die "--image IMAGE required (or set BDFS_BOOTC_IMAGE)"

    require_bootc
    info "Switching to bootc image: $image"
    $BOOTC_CMD switch "$image"
    info "Staged. Reboot to activate."
}

# ── upgrade ───────────────────────────────────────────────────────────────────

cmd_upgrade() {
    local check=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) check=true; shift ;;
            -*)      die "Unknown option: $1" ;;
            *)       die "Unexpected argument: $1" ;;
        esac
    done

    require_bootc
    if $check; then
        info "Checking for bootc upgrade"
        $BOOTC_CMD upgrade --check
    else
        info "Upgrading bootc image"
        $BOOTC_CMD upgrade
        info "Staged. Reboot to activate."
    fi
}

# ── export ────────────────────────────────────────────────────────────────────

cmd_export() {
    local source="" out="" compression="zstd"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)      source="$2";      shift 2 ;;
            --out)         out="$2";         shift 2 ;;
            --compression) compression="$2"; shift 2 ;;
            -*)            die "Unknown option: $1" ;;
            *)             die "Unexpected argument: $1" ;;
        esac
    done
    [[ -n "$out" ]] || die "--out PATH required"

    require_cmd mkdwarfs "dwarfs (mkdwarfs)"
    source="${source:-/}"

    info "Exporting bootc root ($source) to DwarFS image: $out"
    mkdwarfs -i "$source" -o "$out" --compression "$compression" \
        --exclude-caches \
        --filter "- /proc/**" \
        --filter "- /sys/**" \
        --filter "- /dev/**" \
        --filter "- /run/**" \
        --filter "- /tmp/**"
    info "Exported: $out ($(du -sh "$out" | cut -f1))"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    require_bootc
    echo "=== bootc status ==="
    $BOOTC_CMD status 2>/dev/null || echo "(bootc status unavailable)"
    echo ""
    echo "=== bdfs workspaces ==="
    $BDFS_CMD dev list 2>/dev/null || echo "(no bdfs workspaces)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
    workspace) cmd_workspace "$@" ;;
    commit)    cmd_commit    "$@" ;;
    switch)    cmd_switch    "$@" ;;
    upgrade)   cmd_upgrade   "$@" ;;
    export)    cmd_export    "$@" ;;
    status)    cmd_status    "$@" ;;
    ""|help)
        echo "Usage: bdfs-bootc <subcommand> [options]"
        echo ""
        echo "Subcommands:"
        echo "  workspace  Create a bdfs workspace from the active bootc root"
        echo "  commit     Pack workspace into an OCI image [--push]"
        echo "  switch     Switch to a new bootc image (staged, needs reboot)"
        echo "  upgrade    Upgrade the booted image [--check]"
        echo "  export     Export bootc root as a DwarFS image"
        echo "  status     Show bootc status and bdfs workspaces"
        ;;
    *) die "Unknown subcommand: $SUBCOMMAND (run bdfs-bootc help)" ;;
esac
