#!/usr/bin/env bash
# Opt-in repository-local Git performance settings; never changes global config.
set -euo pipefail

usage() {
  echo "Usage: $0 enable|disable|status"
  echo "enable: configure built-in FSMonitor only on supported macOS/Windows Git"
  echo "disable: remove repository-local FSMonitor setting"
}

command_name="\${1:-}"
if [[ "$command_name" != "enable" && "$command_name" != "disable" && "$command_name" != "status" ]]; then
  usage >&2
  exit 2
fi

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "error: run inside a Git worktree" >&2
  exit 2
}

case "$command_name" in
  status)
    git config --local --show-origin --get core.fsmonitor || true
    git config --local --show-origin --get core.untrackedCache || true
    git fsmonitor--daemon status 2>&1 || true
    ;;
  disable)
    git config --local --unset core.fsmonitor || true
    echo "Repository-local core.fsmonitor removed. untrackedCache left unchanged."
    ;;
  enable)
    version="$(git version | sed -E 's/^git version ([0-9]+\.[0-9]+).*/\1/')"
    major="\${version%%.*}"
    minor="\${version#*.}"
    if (( major < 2 || (major == 2 && minor < 37) )); then
      echo "Git $version is older than the conservative built-in FSMonitor baseline (2.37); no changes made."
      exit 1
    fi
    case "$(uname -s)" in
      Darwin|MINGW*|MSYS*|CYGWIN*)
        ;;
      *)
        echo "Built-in FSMonitor daemon is not enabled automatically on this OS."
        echo "Use a compatible external fsmonitor hook only after separately validating it."
        exit 1
        ;;
    esac
    if ! git fsmonitor--daemon start; then
      echo "Could not start fsmonitor daemon; no config changes made." >&2
      exit 1
    fi
    if ! git update-index --test-untracked-cache >/dev/null 2>&1; then
      echo "This worktree does not pass Git's untracked-cache test; stopping daemon." >&2
      git fsmonitor--daemon stop >/dev/null 2>&1 || true
      exit 1
    fi
    git config --local core.fsmonitor true
    git config --local core.untrackedCache true
    echo "Enabled repository-local FSMonitor and untracked cache."
    ;;
esac
