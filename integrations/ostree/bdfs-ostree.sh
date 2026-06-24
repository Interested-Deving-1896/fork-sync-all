#!/usr/bin/env bash
# bdfs-ostree — OSTree integration for btrfs-dwarfs-framework
#
# Bridges OSTree's immutable deployment model with bdfs's snapshot and
# workspace capabilities. Provides helpers for:
#
#   commit    Commit a bdfs workspace back to an OSTree repo
#   publish   Commit + ostree admin deploy (makes it the next boot target)
#   export    Export an OSTree commit as a DwarFS image via bdfs export
#   import    Import a DwarFS image into an OSTree repo as a new commit
#   prune     Remove old OSTree deployments, keeping N most recent
#   status    Show current OSTree deployments and their bdfs workspace state
#
# Environment:
#   BDFS_OSTREE_REPO    Default OSTree repo path (overridden by --repo)
#   BDFS_OSTREE_BRANCH  Default branch name     (overridden by --branch)
#
# Dependencies: ostree, bdfs
#
# Usage:
#   bdfs-ostree.sh commit  <workspace-name> [--repo PATH] [--branch BRANCH] [--msg MSG]
#   bdfs-ostree.sh publish <workspace-name> [--repo PATH] [--branch BRANCH]
#   bdfs-ostree.sh export  <commit-ref>     [--repo PATH] --out PATH [--compression zstd]
#   bdfs-ostree.sh import  <image-path>     [--repo PATH] [--branch BRANCH]
#   bdfs-ostree.sh prune   [--repo PATH]    [--keep N]
#   bdfs-ostree.sh status  [--repo PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDFS_CMD="${BDFS_CMD:-bdfs}"
OSTREE_CMD="${OSTREE_CMD:-ostree}"

BDFS_OSTREE_REPO="${BDFS_OSTREE_REPO:-}"
BDFS_OSTREE_BRANCH="${BDFS_OSTREE_BRANCH:-bdfs/main}"
DEFAULT_KEEP=3

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "[bdfs-ostree] $*"; }
die()   { echo "[bdfs-ostree] ERROR: $*" >&2; exit "${2:-1}"; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found — install $2"
}

require_ostree() { require_cmd ostree "ostree (libostree)"; }
require_bdfs()   { require_cmd bdfs   "btrfs-dwarfs-framework"; }

workspace_mountpoint() {
    # Returns the active mountpoint for a bdfs workspace, or dies.
    local name="$1"
    local mp
    mp="$($BDFS_CMD dev status "$name" 2>/dev/null | awk '/mountpoint:/{print $2}')"
    [[ -n "$mp" ]] || die "workspace '$name' is not mounted (run: bdfs dev shell $name)"
    echo "$mp"
}

# ── commit ────────────────────────────────────────────────────────────────────

cmd_commit() {
    local name="" repo="" branch="" message="bdfs-ostree commit $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)    repo="$2";    shift 2 ;;
            --branch)  branch="$2";  shift 2 ;;
            --msg)     message="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         name="$1";    shift ;;
        esac
    done
    [[ -n "$name"   ]] || die "Usage: bdfs-ostree commit <workspace-name> [--repo PATH] [--branch BRANCH]"
    repo="${repo:-$BDFS_OSTREE_REPO}"
    branch="${branch:-$BDFS_OSTREE_BRANCH}"
    [[ -n "$repo"   ]] || die "--repo required (or set BDFS_OSTREE_REPO)"
    [[ -n "$branch" ]] || die "--branch required (or set BDFS_OSTREE_BRANCH)"

    require_ostree
    require_bdfs

    local mp
    mp="$(workspace_mountpoint "$name")"

    info "Committing workspace '$name' ($mp) → OSTree $repo:$branch"
    $OSTREE_CMD commit \
        --repo="$repo" \
        --branch="$branch" \
        --subject="$message" \
        --tree=dir="$mp"
    info "Committed. New HEAD: $($OSTREE_CMD rev-parse --repo="$repo" "$branch")"
}

# ── publish ───────────────────────────────────────────────────────────────────

cmd_publish() {
    local name="" repo="" branch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)   repo="$2";   shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            -*)       die "Unknown option: $1" ;;
            *)        name="$1";   shift ;;
        esac
    done
    [[ -n "$name" ]] || die "Usage: bdfs-ostree publish <workspace-name> [--repo PATH] [--branch BRANCH]"
    repo="${repo:-$BDFS_OSTREE_REPO}"
    branch="${branch:-$BDFS_OSTREE_BRANCH}"
    [[ -n "$repo"   ]] || die "--repo required"
    [[ -n "$branch" ]] || die "--branch required"

    require_ostree
    require_bdfs

    # Commit first, then deploy
    cmd_commit "$name" --repo "$repo" --branch "$branch"

    info "Deploying $branch to next boot slot"
    $OSTREE_CMD admin deploy --os=default "$branch"
    info "Published. Reboot to activate."
}

# ── export ────────────────────────────────────────────────────────────────────

cmd_export() {
    local ref="" repo="" out="" compression="zstd"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)        repo="$2";        shift 2 ;;
            --out)         out="$2";         shift 2 ;;
            --compression) compression="$2"; shift 2 ;;
            -*)            die "Unknown option: $1" ;;
            *)             ref="$1";         shift ;;
        esac
    done
    [[ -n "$ref" ]] || die "Usage: bdfs-ostree export <commit-ref> --out PATH [--repo PATH] [--compression zstd]"
    [[ -n "$out" ]] || die "--out PATH required"
    repo="${repo:-$BDFS_OSTREE_REPO}"
    [[ -n "$repo" ]] || die "--repo required"

    require_ostree
    require_cmd mkdwarfs "dwarfs (mkdwarfs)"

    local tmpdir
    tmpdir="$(mktemp -d /tmp/bdfs-ostree-export.XXXXXX)"
    trap "rm -rf '$tmpdir'" EXIT

    info "Checking out OSTree ref '$ref' to $tmpdir"
    $OSTREE_CMD checkout --repo="$repo" "$ref" "$tmpdir/checkout"

    info "Packing to DwarFS image: $out"
    mkdwarfs -i "$tmpdir/checkout" -o "$out" --compression "$compression"
    info "Exported: $out ($(du -sh "$out" | cut -f1))"
}

# ── import ────────────────────────────────────────────────────────────────────

cmd_import() {
    local image="" repo="" branch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)   repo="$2";   shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            -*)       die "Unknown option: $1" ;;
            *)        image="$1";  shift ;;
        esac
    done
    [[ -n "$image"  ]] || die "Usage: bdfs-ostree import <image-path> [--repo PATH] [--branch BRANCH]"
    [[ -f "$image"  ]] || die "Image not found: $image"
    repo="${repo:-$BDFS_OSTREE_REPO}"
    branch="${branch:-$BDFS_OSTREE_BRANCH}"
    [[ -n "$repo"   ]] || die "--repo required"
    [[ -n "$branch" ]] || die "--branch required"

    require_ostree
    require_cmd dwarfs "dwarfs"

    local tmpdir mp
    tmpdir="$(mktemp -d /tmp/bdfs-ostree-import.XXXXXX)"
    mp="$tmpdir/mount"
    mkdir -p "$mp"
    trap "fusermount -u '$mp' 2>/dev/null; rm -rf '$tmpdir'" EXIT

    info "Mounting DwarFS image: $image"
    dwarfs "$image" "$mp"

    info "Committing to OSTree $repo:$branch"
    $OSTREE_CMD commit \
        --repo="$repo" \
        --branch="$branch" \
        --subject="bdfs-ostree import $(basename "$image") $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --tree=dir="$mp"
    info "Imported. New HEAD: $($OSTREE_CMD rev-parse --repo="$repo" "$branch")"
}

# ── prune ─────────────────────────────────────────────────────────────────────

cmd_prune() {
    local repo="" keep="$DEFAULT_KEEP"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --keep) keep="$2"; shift 2 ;;
            *)      die "Unknown option: $1" ;;
        esac
    done
    repo="${repo:-$BDFS_OSTREE_REPO}"
    [[ -n "$repo" ]] || die "--repo required"

    require_ostree

    info "Pruning OSTree repo $repo (keeping $keep deployments)"
    $OSTREE_CMD admin undeploy --os=default 2>/dev/null || true
    $OSTREE_CMD prune --repo="$repo" --refs-only --keep-younger-than="$keep days ago" 2>/dev/null || \
        $OSTREE_CMD prune --repo="$repo" --depth="$keep"
    info "Prune complete."
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    local repo=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *)      die "Unknown option: $1" ;;
        esac
    done
    repo="${repo:-$BDFS_OSTREE_REPO}"
    [[ -n "$repo" ]] || die "--repo required"

    require_ostree

    echo "=== OSTree deployments ==="
    $OSTREE_CMD admin status 2>/dev/null || echo "(ostree admin not available)"
    echo ""
    echo "=== OSTree repo refs ($repo) ==="
    $OSTREE_CMD refs --repo="$repo" 2>/dev/null || echo "(repo not found)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
    commit)  cmd_commit  "$@" ;;
    publish) cmd_publish "$@" ;;
    export)  cmd_export  "$@" ;;
    import)  cmd_import  "$@" ;;
    prune)   cmd_prune   "$@" ;;
    status)  cmd_status  "$@" ;;
    ""|help)
        echo "Usage: bdfs-ostree <subcommand> [options]"
        echo ""
        echo "Subcommands:"
        echo "  commit   <workspace>  Commit bdfs workspace to OSTree repo"
        echo "  publish  <workspace>  Commit + deploy (active on next boot)"
        echo "  export   <ref>        Export OSTree commit as DwarFS image"
        echo "  import   <image>      Import DwarFS image into OSTree repo"
        echo "  prune                 Remove old deployments"
        echo "  status                Show deployments and repo refs"
        ;;
    *) die "Unknown subcommand: $SUBCOMMAND (run bdfs-ostree help)" ;;
esac
