#!/usr/bin/env bash
# bdfs dev — mutable development workspaces on top of immutable filesystem roots
#
# Provides three backends, selectable per workspace:
#
#   btrfs    (default) BTRFS writable snapshot of a source root. Full CoW,
#                      persistent, can be committed back to OSTree or archived
#                      as a DwarFS image. Requires the source to be on a BTRFS
#                      filesystem.
#
#   overlay            overlayfs ephemeral workspace. Lightweight, no copy
#                      needed, changes live in a tmpfs or directory upper layer.
#                      Discarded on drop unless explicitly saved. Works on any
#                      filesystem.
#
#   dwarfs             Mounts a DwarFS image read-only as the lower layer, adds
#                      a BTRFS or tmpfs upper layer via overlayfs. Useful for
#                      working on archived/compressed roots without full
#                      extraction.
#
# OSTree integration (optional, auto-detected):
#   When --ostree-repo is provided (or BDFS_OSTREE_REPO is set), the commit
#   and publish subcommands interact with an OSTree repository. Without it,
#   bdfs dev works purely at the filesystem level.
#
# Usage:
#   bdfs dev create  [--name NAME] [--source PATH] [--backend btrfs|overlay|dwarfs]
#                    [--ostree-repo PATH] [--ostree-branch BRANCH]
#                    [--upper PATH] [--tmpfs-size SIZE]
#   bdfs dev list
#   bdfs dev shell   NAME [-- CMD...]
#   bdfs dev status  NAME
#   bdfs dev commit  NAME [--ostree-repo PATH] [--ostree-branch BRANCH]
#                         [--message MSG]
#   bdfs dev publish NAME [--ostree-repo PATH] [--ostree-branch BRANCH]
#   bdfs dev demote  NAME [--compression ALGO] [--keep]
#   bdfs dev drop    NAME [--demote] [--force]
#
# Environment:
#   BDFS_STATE_DIR     Where workspace metadata is stored (default: /var/lib/bdfs/dev)
#   BDFS_OSTREE_REPO   Default OSTree repo path
#   BDFS_BTRFS_MOUNT   Default BTRFS mount for snapshot storage
#
# Exit codes:
#   0  success
#   1  usage error
#   2  workspace not found
#   3  backend error (BTRFS, overlayfs, DwarFS)
#   4  OSTree error
#   5  dependency missing

set -euo pipefail

BDFS_STATE_DIR="${BDFS_STATE_DIR:-/var/lib/bdfs/dev}"
BDFS_OSTREE_REPO="${BDFS_OSTREE_REPO:-}"
BDFS_BTRFS_MOUNT="${BDFS_BTRFS_MOUNT:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Logging ───────────────────────────────────────────────────────────────────

info()  { echo "[bdfs dev] $*"; }
ok()    { echo "[bdfs dev] ✓ $*"; }
warn()  { echo "[bdfs dev] WARN: $*" >&2; }
die()   { echo "[bdfs dev] ERROR: $*" >&2; exit "${2:-1}"; }

# ── Dependency checks ─────────────────────────────────────────────────────────

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1 — install $2" 5
}

check_deps_btrfs() {
    require_cmd btrfs "btrfs-progs"
}

check_deps_overlay() {
    # overlayfs is a kernel module — check it's available
    modinfo overlay &>/dev/null || \
        grep -q overlay /proc/filesystems 2>/dev/null || \
        die "overlayfs not available in this kernel" 3
}

check_deps_dwarfs() {
    require_cmd dwarfs "dwarfs"
    check_deps_overlay
}

check_deps_ostree() {
    require_cmd ostree "ostree"
}

# ── State management ──────────────────────────────────────────────────────────

workspace_dir()  { echo "${BDFS_STATE_DIR}/$1"; }
workspace_meta() { echo "${BDFS_STATE_DIR}/$1/meta"; }

workspace_exists() {
    [[ -d "${BDFS_STATE_DIR}/$1" ]] && [[ -f "$(workspace_meta "$1")" ]]
}

workspace_get() {
    local name="$1" key="$2"
    local meta
    meta="$(workspace_meta "$name")"
    grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2- || true
}

workspace_set() {
    local name="$1" key="$2" value="$3"
    local meta
    meta="$(workspace_meta "$name")"
    if grep -q "^${key}=" "$meta" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$meta"
    else
        echo "${key}=${value}" >> "$meta"
    fi
}

workspace_create_meta() {
    local name="$1"
    local dir
    dir="$(workspace_dir "$name")"
    mkdir -p "$dir"
    cat > "$(workspace_meta "$name")" << EOF
name=${name}
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
state=created
EOF
}

list_workspaces() {
    [[ -d "$BDFS_STATE_DIR" ]] || { info "No workspaces found."; return; }
    local found=0
    for meta in "${BDFS_STATE_DIR}"/*/meta; do
        [[ -f "$meta" ]] || continue
        local name state backend source
        name=$(grep "^name=" "$meta" | cut -d= -f2-)
        state=$(grep "^state=" "$meta" | cut -d= -f2-)
        backend=$(grep "^backend=" "$meta" | cut -d= -f2-)
        source=$(grep "^source=" "$meta" | cut -d= -f2-)
        printf "  %-20s  %-10s  %-10s  %s\n" "$name" "$state" "$backend" "$source"
        ((found++))
    done
    [[ $found -gt 0 ]] || info "No workspaces found."
}

# ── Subcommand: create ────────────────────────────────────────────────────────

cmd_create() {
    local name="" source="" backend="btrfs" ostree_repo="" ostree_branch=""
    local upper="" tmpfs_size="2G"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)           name="$2";          shift 2 ;;
            --source)         source="$2";        shift 2 ;;
            --backend)        backend="$2";       shift 2 ;;
            --ostree-repo)    ostree_repo="$2";   shift 2 ;;
            --ostree-branch)  ostree_branch="$2"; shift 2 ;;
            --upper)          upper="$2";         shift 2 ;;
            --tmpfs-size)     tmpfs_size="$2";    shift 2 ;;
            *) die "Unknown option: $1" 1 ;;
        esac
    done

    # Auto-generate name if not provided
    if [[ -z "$name" ]]; then
        name="dev-$(date +%Y%m%d-%H%M%S)"
        info "No name given — using: $name"
    fi

    workspace_exists "$name" && die "Workspace '$name' already exists" 1

    [[ -z "$source" ]] && die "--source is required" 1

    case "$backend" in
        btrfs|overlay|dwarfs) ;;
        *) die "Unknown backend: $backend (choose: btrfs, overlay, dwarfs)" 1 ;;
    esac

    # Use env fallback for ostree repo
    ostree_repo="${ostree_repo:-$BDFS_OSTREE_REPO}"

    info "Creating workspace '$name' (backend: $backend, source: $source)"

    workspace_create_meta "$name"
    workspace_set "$name" backend    "$backend"
    workspace_set "$name" source     "$source"
    workspace_set "$name" tmpfs_size "$tmpfs_size"
    [[ -n "$ostree_repo"    ]] && workspace_set "$name" ostree_repo   "$ostree_repo"
    [[ -n "$ostree_branch"  ]] && workspace_set "$name" ostree_branch "$ostree_branch"
    [[ -n "$upper"          ]] && workspace_set "$name" upper         "$upper"

    # Delegate to backend
    case "$backend" in
        btrfs)   source "$SCRIPT_DIR/bdfs-dev-btrfs.sh";   backend_create "$name" "$source" ;;
        overlay) source "$SCRIPT_DIR/bdfs-dev-overlay.sh"; backend_create "$name" "$source" "$tmpfs_size" "$upper" ;;
        dwarfs)  source "$SCRIPT_DIR/bdfs-dev-dwarfs.sh";  backend_create "$name" "$source" "$tmpfs_size" "$upper" ;;
    esac

    workspace_set "$name" state "ready"
    ok "Workspace '$name' ready — use: bdfs dev shell $name"
}

# ── Subcommand: shell ─────────────────────────────────────────────────────────

cmd_shell() {
    local name="${1:-}"
    shift || true
    [[ -z "$name" ]] && die "Usage: bdfs dev shell NAME [-- CMD...]" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    local mountpoint backend
    mountpoint="$(workspace_get "$name" mountpoint)"
    backend="$(workspace_get "$name" backend)"

    [[ -z "$mountpoint" ]] && die "Workspace '$name' has no mountpoint recorded" 2
    [[ -d "$mountpoint" ]] || die "Mountpoint $mountpoint does not exist" 3

    info "Entering workspace '$name' ($backend) at $mountpoint"

    if [[ $# -gt 0 && "$1" == "--" ]]; then
        shift
        chroot "$mountpoint" "$@"
    elif [[ $# -gt 0 ]]; then
        chroot "$mountpoint" "$@"
    else
        chroot "$mountpoint" /bin/bash --login || \
        chroot "$mountpoint" /bin/sh
    fi
}

# ── Subcommand: status ────────────────────────────────────────────────────────

cmd_status() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: bdfs dev status NAME" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    local meta
    meta="$(workspace_meta "$name")"
    echo "Workspace: $name"
    echo "---"
    cat "$meta"

    local mountpoint
    mountpoint="$(workspace_get "$name" mountpoint)"
    if [[ -n "$mountpoint" ]]; then
        echo "---"
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            echo "mount: active at $mountpoint"
            df -h "$mountpoint" 2>/dev/null | tail -1 || true
        else
            echo "mount: not mounted"
        fi
    fi
}

# ── Subcommand: commit ────────────────────────────────────────────────────────

cmd_commit() {
    local name="${1:-}"
    shift || true
    [[ -z "$name" ]] && die "Usage: bdfs dev commit NAME [--ostree-repo PATH] [--ostree-branch BRANCH] [--message MSG]" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    local ostree_repo ostree_branch message=""
    ostree_repo="$(workspace_get "$name" ostree_repo)"
    ostree_branch="$(workspace_get "$name" ostree_branch)"
    ostree_repo="${ostree_repo:-$BDFS_OSTREE_REPO}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ostree-repo)    ostree_repo="$2";   shift 2 ;;
            --ostree-branch)  ostree_branch="$2"; shift 2 ;;
            --message|-m)     message="$2";       shift 2 ;;
            *) die "Unknown option: $1" 1 ;;
        esac
    done

    [[ -z "$ostree_repo"   ]] && die "--ostree-repo required (or set BDFS_OSTREE_REPO)" 1
    [[ -z "$ostree_branch" ]] && die "--ostree-branch required" 1

    check_deps_ostree

    local mountpoint
    mountpoint="$(workspace_get "$name" mountpoint)"
    [[ -z "$mountpoint" ]] && die "No mountpoint for workspace '$name'" 2

    message="${message:-bdfs dev commit: $name $(date -u +%Y-%m-%dT%H:%M:%SZ)}"

    info "Committing workspace '$name' to OSTree branch '$ostree_branch'"
    info "  repo:    $ostree_repo"
    info "  source:  $mountpoint"

    ostree commit \
        --repo="$ostree_repo" \
        --branch="$ostree_branch" \
        --subject="$message" \
        --tree=dir="$mountpoint"

    local commit_hash
    commit_hash="$(ostree rev-parse --repo="$ostree_repo" "$ostree_branch")"
    workspace_set "$name" last_commit "$commit_hash"
    workspace_set "$name" last_commit_branch "$ostree_branch"

    ok "Committed as $commit_hash on branch '$ostree_branch'"
}

# ── Subcommand: publish ───────────────────────────────────────────────────────

cmd_publish() {
    local name="${1:-}"
    shift || true
    [[ -z "$name" ]] && die "Usage: bdfs dev publish NAME [--ostree-repo PATH] [--ostree-branch BRANCH]" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    # commit first, then deploy
    cmd_commit "$name" "$@"

    local ostree_repo ostree_branch
    ostree_repo="$(workspace_get "$name" ostree_repo)"
    ostree_branch="$(workspace_get "$name" ostree_branch)"
    ostree_repo="${ostree_repo:-$BDFS_OSTREE_REPO}"

    info "Deploying branch '$ostree_branch' from $ostree_repo"
    ostree admin deploy \
        --os=default \
        "$ostree_branch"

    ok "Deployed — reboot to activate"
}

# ── Subcommand: demote ────────────────────────────────────────────────────────

cmd_demote() {
    local name="${1:-}"
    shift || true
    [[ -z "$name" ]] && die "Usage: bdfs dev demote NAME [--compression ALGO] [--keep]" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    local compression="zstd" keep=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compression) compression="$2"; shift 2 ;;
            --keep)        keep=true;        shift ;;
            *) die "Unknown option: $1" 1 ;;
        esac
    done

    local mountpoint backend
    mountpoint="$(workspace_get "$name" mountpoint)"
    backend="$(workspace_get "$name" backend)"

    [[ -z "$mountpoint" ]] && die "No mountpoint for workspace '$name'" 2

    local image_path="${BDFS_STATE_DIR}/${name}/${name}.dwarfs"
    info "Demoting workspace '$name' to DwarFS image: $image_path"

    require_cmd mkdwarfs "dwarfs"
    mkdwarfs -i "$mountpoint" -o "$image_path" --compression "$compression"

    workspace_set "$name" dwarfs_image "$image_path"
    workspace_set "$name" state "demoted"

    if [[ "$keep" == "false" ]]; then
        case "$backend" in
            btrfs)
                source "$SCRIPT_DIR/bdfs-dev-btrfs.sh"
                backend_drop "$name"
                ;;
            overlay|dwarfs)
                source "$SCRIPT_DIR/bdfs-dev-overlay.sh"
                backend_drop "$name"
                ;;
        esac
    fi

    ok "Demoted to $image_path ($(du -sh "$image_path" | cut -f1))"
}

# ── Subcommand: drop ──────────────────────────────────────────────────────────

cmd_drop() {
    local name="${1:-}"
    shift || true
    [[ -z "$name" ]] && die "Usage: bdfs dev drop NAME [--demote] [--force]" 1
    workspace_exists "$name" || die "Workspace '$name' not found" 2

    local do_demote=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --demote) do_demote=true; shift ;;
            --force)  force=true;     shift ;;
            *) die "Unknown option: $1" 1 ;;
        esac
    done

    local state
    state="$(workspace_get "$name" state)"

    if [[ "$state" == "ready" ]] && [[ "$force" == "false" ]] && [[ "$do_demote" == "false" ]]; then
        warn "Workspace '$name' has uncommitted changes."
        read -r -p "Drop anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
    fi

    [[ "$do_demote" == "true" ]] && cmd_demote "$name"

    local backend
    backend="$(workspace_get "$name" backend)"

    info "Dropping workspace '$name'"
    case "$backend" in
        btrfs)
            source "$SCRIPT_DIR/bdfs-dev-btrfs.sh"
            backend_drop "$name"
            ;;
        overlay|dwarfs)
            source "$SCRIPT_DIR/bdfs-dev-overlay.sh"
            backend_drop "$name"
            ;;
    esac

    rm -rf "$(workspace_dir "$name")"
    ok "Workspace '$name' dropped"
}

# ── Main dispatcher ───────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
bdfs dev — mutable development workspaces on immutable filesystem roots

Backends:
  btrfs    BTRFS writable snapshot (default, persistent, CoW)
  overlay  overlayfs ephemeral workspace (lightweight, any filesystem)
  dwarfs   DwarFS image + overlayfs upper layer (work on compressed roots)

Subcommands:
  create   Create a new workspace
  list     List all workspaces
  shell    Enter a workspace (chroot)
  status   Show workspace details
  commit   Commit workspace to an OSTree branch
  publish  Commit and deploy via ostree admin deploy
  demote   Compress workspace to a DwarFS image
  drop     Destroy a workspace

Examples:
  # BTRFS snapshot of an OSTree deployment
  bdfs dev create \
      --name my-feature \
      --source /ostree/deploy/default/deploy/<hash> \
      --backend btrfs \
      --ostree-repo /ostree/repo \
      --ostree-branch dev/my-feature

  # Ephemeral overlay (no BTRFS needed)
  bdfs dev create \
      --name quick-test \
      --source /path/to/rootfs \
      --backend overlay \
      --tmpfs-size 1G

  # Work on a compressed DwarFS archive
  bdfs dev create \
      --name archived-work \
      --source /path/to/image.dwarfs \
      --backend dwarfs

  # Enter, make changes, commit back to OSTree
  bdfs dev shell my-feature
  bdfs dev commit my-feature --message "add debug tooling"

  # Archive and clean up
  bdfs dev drop my-feature --demote
EOF
}

main() {
    [[ $# -eq 0 ]] && { usage; exit 0; }

    local subcmd="$1"
    shift

    case "$subcmd" in
        create)  cmd_create  "$@" ;;
        list)    list_workspaces ;;
        shell)   cmd_shell   "$@" ;;
        status)  cmd_status  "$@" ;;
        commit)  cmd_commit  "$@" ;;
        publish) cmd_publish "$@" ;;
        demote)  cmd_demote  "$@" ;;
        drop)    cmd_drop    "$@" ;;
        help|--help|-h) usage ;;
        *) die "Unknown subcommand: $subcmd — run 'bdfs dev help'" 1 ;;
    esac
}

main "$@"
