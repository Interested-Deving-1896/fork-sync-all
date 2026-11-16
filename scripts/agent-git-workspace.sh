#!/usr/bin/env bash
# Safe, local-first Git workspace helper for authorized agents.
# This helper never checks out, resets, merges, pushes, or deletes branches.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/agent-git-workspace.sh check
  scripts/agent-git-workspace.sh clone OWNER/REPO [TARGET_DIR]
  scripts/agent-git-workspace.sh fetch WORKTREE [REMOTE]
  scripts/agent-git-workspace.sh status WORKTREE
  scripts/agent-git-workspace.sh diff WORKTREE
  scripts/agent-git-workspace.sh fork OWNER/REPO --confirm

Commands:
  check     Report availability of git and (optionally) gh; no network access.
  clone     Clone a public GitHub repository into a new directory.
  fetch     Fetch remote refs only; never changes the checked-out branch/worktree.
  status    Show branch, HEAD, remotes, and working-tree state.
  diff      Show tracked working-tree diff (does not include untracked files).
  fork      Create a GitHub fork only with the explicit --confirm flag and gh auth.

Safety:
  - OWNER/REPO is validated and converted to an HTTPS GitHub URL.
  - clone refuses to overwrite an existing target directory.
  - fetch requires a Git worktree and a named configured remote.
  - no push, merge, reset, checkout, pull, or automatic fork creation.
USAGE
}

die() { printf '[agent-git-workspace] error: %s\n' "$*" >&2; exit 2; }
info() { printf '[agent-git-workspace] %s\n' "$*" >&2; }

valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] &&
    [[ "$1" != */. ]] && [[ "$1" != */.. ]]
}

need_git() { command -v git >/dev/null 2>&1 || die "git is not installed"; }
need_repo() { valid_repo "$1" || die "expected OWNER/REPO using letters, digits, dot, underscore, or hyphen"; }

command_name="${1:-}"
case "$command_name" in
  check)
    if command -v git >/dev/null 2>&1; then
      printf 'git: available (%s)\n' "$(git --version)"
    else
      printf 'git: unavailable\n'
    fi
    if command -v gh >/dev/null 2>&1; then
      printf 'gh: available (%s)\n' "$(gh --version | head -n 1)"
      if gh auth status >/dev/null 2>&1; then printf 'gh-auth: authenticated\n'; else printf 'gh-auth: unavailable\n'; fi
    else
      printf 'gh: unavailable\n'
      printf 'gh-auth: unavailable\n'
    fi
    ;;
  clone)
    need_git
    repo="${2:-}"; target="${3:-}"
    [[ -n "$repo" ]] || die "clone requires OWNER/REPO"
    need_repo "$repo"
    [[ -n "$target" ]] || target="${repo##*/}"
    [[ ! -e "$target" ]] || die "target already exists: $target"
    git clone -- "$([ -n "$repo" ] && printf 'https://github.com/%s.git' "$repo")" "$target"
    ;;
  fetch)
    need_git
    worktree="${2:-}"; remote="${3:-origin}"
    [[ -n "$worktree" ]] || die "fetch requires WORKTREE"
    git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $worktree"
    git -C "$worktree" remote get-url "$remote" >/dev/null 2>&1 || die "unknown remote: $remote"
    info "fetching refs from remote '$remote'; local files and current branch are not changed"
    git -C "$worktree" fetch --no-tags "$remote"
    ;;
  status)
    need_git
    worktree="${2:-}"
    [[ -n "$worktree" ]] || die "status requires WORKTREE"
    git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $worktree"
    printf 'root: '; git -C "$worktree" rev-parse --show-toplevel
    printf 'branch: '; git -C "$worktree" branch --show-current
    printf 'HEAD: '; git -C "$worktree" rev-parse HEAD
    printf '\nremotes:\n'; git -C "$worktree" remote -v
    printf '\nworking tree:\n'; git -C "$worktree" status --short --branch
    ;;
  diff)
    need_git
    worktree="${2:-}"
    [[ -n "$worktree" ]] || die "diff requires WORKTREE"
    git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $worktree"
    git -C "$worktree" diff --no-ext-diff --no-color
    ;;
  fork)
    need_git
    repo="${2:-}"; confirmation="${3:-}"
    [[ -n "$repo" ]] || die "fork requires OWNER/REPO"
    need_repo "$repo"
    [[ "$confirmation" == "--confirm" ]] || die "fork creation is a remote write; repeat with --confirm"
    command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required to create a fork"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run gh auth login explicitly"
    info "creating a GitHub fork of $repo (explicitly confirmed)"
    gh repo fork "$repo" --remote=false
    ;;
  -h|--help|"") usage ;;
  *) usage >&2; die "unknown command: $command_name" ;;
esac
