#!/usr/bin/env bash
# scripts/includes/shell-tools.sh — wrapper functions for vendored shell-tools
#
# Source this file to call any shell-tool from fork-sync-all workflows.
# All tools are resolved from vendor/shell-tools/<tool>/ relative to REPO_ROOT.
#
# Usage:
#   source scripts/includes/shell-tools.sh
#   sizes_report /some/path
#   namefix_check "bad filename.txt"
#   jail_run "bash myscript.sh"
#   hrsync_backup /src /dst
#
# All functions:
#   - Write status to stderr (never stdout) so callers can capture output
#   - Return 0 on success, non-zero on failure
#   - Are non-fatal by default — callers decide whether to abort on failure
#   - Resolve tool paths relative to REPO_ROOT (set by the calling workflow)

[[ -n "${_SHELL_TOOLS_LOADED:-}" ]] && return 0
_SHELL_TOOLS_LOADED=1

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
_ST_DIR="$REPO_ROOT/vendor/shell-tools"

_st_info() { echo "[shell-tools] $*" >&2; }
_st_warn() { echo "[shell-tools:warn] $*" >&2; }

# _st_tool_path TOOL_DIR ENTRYPOINT
# Resolves the path to a tool's entrypoint, trying common locations.
_st_tool_path() {
  local dir="$_ST_DIR/$1" entry="$2"
  for candidate in "$dir/$entry" "$dir/${entry%.sh}.sh" "$dir/${entry}.sh" "$dir/$(basename "$entry")"; do
    [[ -f "$candidate" ]] && echo "$candidate" && return 0
  done
  echo "" && return 1
}

# ── Filesystem / security ─────────────────────────────────────────────────────

# tomb_run ACTION [ARGS...] — run tomb with given action (open, close, forge, lock)
tomb_run() {
  local action="${1:-version}"; shift || true
  local tomb_bin
  tomb_bin="$(_st_tool_path tomb tomb)" || { _st_warn "tomb not vendored"; return 1; }
  _st_info "tomb $action $*"
  bash "$tomb_bin" "$action" "$@"
}

# sizes_report [PATH] — print extension-based disk usage for PATH (default: .)
sizes_report() {
  local path="${1:-.}"
  local script
  script="$(_st_tool_path sizes sizes.sh)" || { _st_warn "sizes not vendored"; return 1; }
  _st_info "sizes report: $path"
  bash "$script" "$path" 2>/dev/null
}

# rm_safely PATH [PATH...] — move files to trash instead of deleting
rm_safely() {
  local script
  script="$(_st_tool_path rm-safely rm-safely.sh)" || { _st_warn "rm-safely not vendored"; return 1; }
  _st_info "rm-safely: $*"
  bash "$script" "$@"
}

# swap_files FILE_A FILE_B — atomically swap two files
swap_files() {
  local a="$1" b="$2"
  local script
  script="$(_st_tool_path swap.sh swap)" || { _st_warn "swap.sh not vendored"; return 1; }
  _st_info "swap: $a <-> $b"
  bash "$script" "$a" "$b"
}

# jail_run COMMAND [ARGS...] — run command in Landlock-restricted bash shell
jail_run() {
  local script
  script="$(_st_tool_path jail-sh jail.sh)" || { _st_warn "jail-sh not vendored"; return 1; }
  _st_info "jail: $*"
  bash "$script" "$@"
}

# mist_sync SRC DST [SSH_HOST] — sync directory securely via SSH filesystem
mist_sync() {
  local src="$1" dst="$2"
  local script
  script="$(_st_tool_path mist.sh mist.sh)" || { _st_warn "mist.sh not vendored"; return 1; }
  _st_info "mist sync: $src -> $dst"
  bash "$script" "$src" "$dst" "${3:-}"
}

# smart_organize DIR — auto-sort files in DIR into type-based subdirectories
smart_organize() {
  local dir="${1:-.}"
  local script
  script="$(_st_tool_path Smart-File-Organizer fixfolder.sh)" || { _st_warn "Smart-File-Organizer not vendored"; return 1; }
  _st_info "smart-organize: $dir"
  bash "$script" "$dir"
}

# namefix_check FILENAME — validate/sanitize a filename, print safe version
namefix_check() {
  local name="$1"
  local script
  script="$(_st_tool_path namefix namefix.sh)" || { _st_warn "namefix not vendored"; return 1; }
  _st_info "namefix: $name"
  bash "$script" "$name"
}

# user_filesystem_report — print active user filesystem representation
user_filesystem_report() {
  local script
  script="$(_st_tool_path User-Filesystem user-filesystem.sh)" || { _st_warn "User-Filesystem not vendored"; return 1; }
  _st_info "user-filesystem report"
  bash "$script"
}

# mkinitcpio_dir_info — print mkinitcpio-dir hook info
mkinitcpio_dir_info() {
  local dir="$_ST_DIR/mkinitcpio-dir"
  _st_info "mkinitcpio-dir contents:"
  ls "$dir" 2>/dev/null || _st_warn "mkinitcpio-dir not vendored"
}

# bibhelper_query QUERY — query the bibliographic database
bibhelper_query() {
  local query="$1"
  local script
  script="$(_st_tool_path bibhelper bh)" || { _st_warn "bibhelper not vendored"; return 1; }
  _st_info "bibhelper: $query"
  bash "$script" "$query"
}

# ── Sync / backup ─────────────────────────────────────────────────────────────

# hrsync_backup SRC DST [OPTIONS] — rsync backup with rename/move detection
hrsync_backup() {
  local src="$1" dst="$2"; shift 2 || true
  local script
  script="$(_st_tool_path hrsync hrsync)" || { _st_warn "hrsync not vendored"; return 1; }
  _st_info "hrsync: $src -> $dst"
  bash "$script" "$src" "$dst" "$@"
}

# remote_sync_run SRC REMOTE_DST — sync folder to remote server
remote_sync_run() {
  local src="$1" dst="$2"
  local script
  script="$(_st_tool_path remote-sync remote_sync)" || { _st_warn "remote-sync not vendored"; return 1; }
  _st_info "remote-sync: $src -> $dst"
  bash "$script" "$src" "$dst"
}

# ── Shell automation ──────────────────────────────────────────────────────────

# shellqueue_enqueue COMMAND — enqueue a shell command in the filesystem queue
shellqueue_enqueue() {
  local cmd="$1"
  local script
  script="$(_st_tool_path shellqueue shellqueue)" || { _st_warn "shellqueue not vendored"; return 1; }
  _st_info "shellqueue: enqueue '$cmd'"
  python3 "$script" enqueue "$cmd"
}

# smartcd_init — source smartcd into current shell session
smartcd_init() {
  local script
  script="$(_st_tool_path smartcd smartcd.sh)" || { _st_warn "smartcd not vendored"; return 1; }
  _st_info "smartcd: initialising"
  # shellcheck disable=SC1090
  source "$script"
}

# utility_shell_run SCRIPT_NAME [ARGS] — run a utility_shell script by name
utility_shell_run() {
  local name="$1"; shift || true
  local dir="$_ST_DIR/utility_shell"
  local script
  script="$(find "$dir" -name "${name}*" -type f 2>/dev/null | head -1)"
  if [[ -z "$script" ]]; then
    _st_warn "utility_shell: script '$name' not found in vendor"
    return 1
  fi
  _st_info "utility_shell: $script $*"
  bash "$script" "$@"
}

# simple_deploy_run APPROACH [ARGS] — run a simple-deploy approach
simple_deploy_run() {
  local approach="${1:-}"
  local dir="$_ST_DIR/simple-deploy"
  _st_info "simple-deploy: $approach"
  if [[ -n "$approach" && -f "$dir/$approach" ]]; then
    bash "$dir/$approach" "${@:2}"
  else
    ls "$dir" 2>/dev/null || _st_warn "simple-deploy not vendored"
  fi
}

# shell_archive_search PATTERN — search archived .sh files for pattern
shell_archive_search() {
  local pattern="${1:-}"
  local dir="$_ST_DIR/linux-shell-script-archive"
  _st_info "shell-archive: searching for '$pattern'"
  find "$dir" -name '*.sh' 2>/dev/null | xargs grep -l "$pattern" 2>/dev/null || true
}

# phantom_shell_run CHALLENGE — run an operation-phantom-shell challenge script
phantom_shell_run() {
  local challenge="${1:-}"
  local dir="$_ST_DIR/operation-phantom-shell"
  _st_info "phantom-shell: $challenge"
  if [[ -n "$challenge" && -f "$dir/$challenge" ]]; then
    bash "$dir/$challenge" "${@:2}"
  else
    ls "$dir" 2>/dev/null || _st_warn "operation-phantom-shell not vendored"
  fi
}

# ── GitHub / org tooling ──────────────────────────────────────────────────────

# ipinfo_lookup IP — look up IP address info via ipinfo.io
ipinfo_lookup() {
  local ip="${1:-}"
  local script
  script="$(_st_tool_path ipinfo ipinfo.sh)" || { _st_warn "ipinfo not vendored"; return 1; }
  _st_info "ipinfo: $ip"
  bash "$script" "$ip"
}

# achievements_unlock — run GitHub achievements unlock scripts
achievements_unlock() {
  local dir="$_ST_DIR/achievements"
  _st_info "achievements: running unlock scripts"
  for script in "$dir"/*.sh; do
    [[ -f "$script" ]] || continue
    _st_info "  running: $(basename "$script")"
    bash "$script" 2>/dev/null || true
  done
}

# mass_clone_org ORG [DEST_DIR] — clone all repos in a GitHub org
mass_clone_org() {
  local org="$1" dest="${2:-.}"
  local script
  script="$(_st_tool_path mass_clone clone_all.sh)" || { _st_warn "mass_clone not vendored"; return 1; }
  _st_info "mass_clone: org=$org dest=$dest"
  bash "$script" "$org" "$dest"
}

# git_release_create REPO TAG [TITLE] [BODY] — create a GitHub release via shell
git_release_create() {
  local repo="$1" tag="$2" title="${3:-$2}" body="${4:-}"
  local dir="$_ST_DIR/git-release-shell"
  local script
  script="$(find "$dir" -name '*.sh' -type f 2>/dev/null | head -1)"
  if [[ -z "$script" ]]; then
    _st_warn "git-release-shell not vendored"
    return 1
  fi
  _st_info "git-release: $repo@$tag"
  REPO="$repo" TAG="$tag" TITLE="$title" BODY="$body" bash "$script"
}

# fswatch_list DIR — list filesystem events for a watchfolder directory
fswatch_list() {
  local dir="${1:-.}"
  local script
  script="$(_st_tool_path fswatch watchfolder.sh)" || { _st_warn "fswatch not vendored"; return 1; }
  _st_info "fswatch: watching $dir"
  bash "$script" "$dir"
}
