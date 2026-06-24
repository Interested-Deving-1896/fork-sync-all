#!/usr/bin/env bash
# bdfs-incusos — IncusOS integration for btrfs-dwarfs-framework
#
# Bridges IncusOS's immutable OS image model with bdfs's snapshot and
# workspace capabilities. IncusOS is an immutable Debian-based OS dedicated
# to running Incus (https://github.com/lxc/incus-os).
#
# Provides helpers for:
#
#   workspace   Create a bdfs workspace from an IncusOS root or image
#   export      Export an IncusOS root/image as a DwarFS archive
#   import      Import a DwarFS archive as an Incus image
#   update      Trigger an IncusOS in-place update (wraps incus-os update)
#   status      Show IncusOS version, Incus status, and bdfs workspaces
#
# Environment:
#   BDFS_INCUSOS_ROOT    Path to IncusOS root (default: /)
#   BDFS_INCUSOS_IMAGES  Directory for exported DwarFS images
#
# Dependencies: incus (for import), bdfs, mkdwarfs/dwarfs
#
# Usage:
#   bdfs-incusos.sh workspace [--source PATH] [--name NAME]
#   bdfs-incusos.sh export    [--source PATH] --out PATH [--compression zstd]
#   bdfs-incusos.sh import    <image-path>   --alias NAME [--type container|vm]
#   bdfs-incusos.sh update    [--check]
#   bdfs-incusos.sh status

set -euo pipefail

BDFS_CMD="${BDFS_CMD:-bdfs}"
INCUS_CMD="${INCUS_CMD:-incus}"

BDFS_INCUSOS_ROOT="${BDFS_INCUSOS_ROOT:-/}"
BDFS_INCUSOS_IMAGES="${BDFS_INCUSOS_IMAGES:-/var/lib/bdfs/incusos-images}"

# ── Helpers ───────────────────────────────────────────────────────────────────

info() { echo "[bdfs-incusos] $*"; }
die()  { echo "[bdfs-incusos] ERROR: $*" >&2; exit "${2:-1}"; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found — install $2"
}

require_bdfs()  { require_cmd bdfs  "btrfs-dwarfs-framework"; }
require_incus() { require_cmd incus "incus (https://linuxcontainers.org/incus)"; }

workspace_mountpoint() {
    local name="$1"
    local mp
    mp="$($BDFS_CMD dev status "$name" 2>/dev/null | awk '/mountpoint:/{print $2}')"
    [[ -n "$mp" ]] || die "workspace '$name' is not mounted (run: bdfs dev shell $name)"
    echo "$mp"
}

# ── workspace ─────────────────────────────────────────────────────────────────

cmd_workspace() {
    local source="" name="incusos-workspace-$(date +%Y%m%d-%H%M%S)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            --name)   name="$2";   shift 2 ;;
            -*)       die "Unknown option: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    require_bdfs
    source="${source:-$BDFS_INCUSOS_ROOT}"

    info "Creating bdfs workspace '$name' from IncusOS root: $source"
    $BDFS_CMD dev create "$name" --source "$source"
    info "Workspace ready. Enter with: bdfs dev shell $name"
    info "Inspect or modify the IncusOS root without affecting the live system."
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
    source="${source:-$BDFS_INCUSOS_ROOT}"

    mkdir -p "$(dirname "$out")"
    info "Exporting IncusOS root ($source) → DwarFS: $out"
    mkdwarfs -i "$source" -o "$out" --compression "$compression" \
        --exclude-caches \
        --filter "- /proc/**" \
        --filter "- /sys/**" \
        --filter "- /dev/**" \
        --filter "- /run/**" \
        --filter "- /tmp/**"
    info "Exported: $out ($(du -sh "$out" | cut -f1))"
}

# ── import ────────────────────────────────────────────────────────────────────

cmd_import() {
    local image="" alias="" type="container"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --alias) alias="$2"; shift 2 ;;
            --type)  type="$2";  shift 2 ;;
            -*)      die "Unknown option: $1" ;;
            *)       image="$1"; shift ;;
        esac
    done
    [[ -n "$image" ]] || die "Usage: bdfs-incusos import <image-path> --alias NAME [--type container|vm]"
    [[ -f "$image" ]] || die "Image not found: $image"
    [[ -n "$alias" ]] || die "--alias NAME required"

    require_incus
    require_cmd dwarfs "dwarfs"

    local tmpdir mp
    tmpdir="$(mktemp -d /tmp/bdfs-incusos-import.XXXXXX)"
    mp="$tmpdir/mount"
    mkdir -p "$mp"
    trap "fusermount -u '$mp' 2>/dev/null; rm -rf '$tmpdir'" EXIT

    info "Mounting DwarFS image: $image"
    dwarfs "$image" "$mp"

    info "Importing into Incus as '$alias' ($type)"
    # Create a minimal metadata.yaml for Incus image import
    cat > "$tmpdir/metadata.yaml" <<EOF
architecture: $(uname -m)
creation_date: $(date +%s)
properties:
  description: IncusOS image imported from $(basename "$image")
  os: incusos
  release: custom
EOF

    # Pack rootfs + metadata for incus image import
    local tarball="$tmpdir/incusos-import.tar.gz"
    tar -czf "$tarball" -C "$tmpdir" metadata.yaml -C "$mp" .

    $INCUS_CMD image import "$tarball" --alias "$alias"
    info "Imported as Incus image '$alias'. Launch with: incus launch $alias <instance-name>"
}

# ── update ────────────────────────────────────────────────────────────────────

cmd_update() {
    local check=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) check=true; shift ;;
            -*)      die "Unknown option: $1" ;;
            *)       die "Unexpected argument: $1" ;;
        esac
    done

    # IncusOS uses systemd-sysupdate or a custom update mechanism
    if command -v systemd-sysupdate &>/dev/null; then
        if $check; then
            info "Checking for IncusOS updates"
            systemd-sysupdate check
        else
            info "Applying IncusOS update"
            systemd-sysupdate update
            info "Update staged. Reboot to activate."
        fi
    elif command -v incus-os &>/dev/null; then
        if $check; then
            incus-os update --check
        else
            incus-os update
        fi
    else
        die "No IncusOS update mechanism found (systemd-sysupdate or incus-os)"
    fi
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== IncusOS version ==="
    cat /etc/os-release 2>/dev/null | grep -E "^(NAME|VERSION|BUILD_ID)" || echo "(not an IncusOS system)"
    echo ""
    echo "=== Incus status ==="
    if command -v incus &>/dev/null; then
        incus info 2>/dev/null | head -20 || echo "(incus not running)"
    else
        echo "(incus not installed)"
    fi
    echo ""
    echo "=== bdfs workspaces ==="
    $BDFS_CMD dev list 2>/dev/null || echo "(no bdfs workspaces)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
    workspace) cmd_workspace "$@" ;;
    export)    cmd_export    "$@" ;;
    import)    cmd_import    "$@" ;;
    update)    cmd_update    "$@" ;;
    status)    cmd_status    "$@" ;;
    ""|help)
        echo "Usage: bdfs-incusos <subcommand> [options]"
        echo ""
        echo "Subcommands:"
        echo "  workspace  Create a bdfs workspace from an IncusOS root"
        echo "  export     Export IncusOS root as a DwarFS image"
        echo "  import     Import a DwarFS image as an Incus image"
        echo "  update     Trigger IncusOS in-place update [--check]"
        echo "  status     Show IncusOS version, Incus status, bdfs workspaces"
        ;;
    *) die "Unknown subcommand: $SUBCOMMAND (run bdfs-incusos help)" ;;
esac
