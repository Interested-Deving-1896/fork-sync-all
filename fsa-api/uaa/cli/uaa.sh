#!/usr/bin/env bash
# cli/uaa.sh — unified-agnostic-api CLI
#
# A bashly-style CLI that routes subcommands to adapter scripts directly
# (no HTTP server required for local use) or proxies to a running server.
#
# Usage:
#   uaa <adapter> <command> [args...]
#   uaa --server http://localhost:8080 <adapter> <command> [args...]
#   uaa server start [--port 8080]
#   uaa help
#
# Generated structure inspired by bashly-framework/bashly CLI generator.
# Install: ln -s $(pwd)/cli/uaa.sh /usr/local/bin/uaa

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/log.sh"

UAA_SERVER="${UAA_SERVER:-}"  # if set, proxy all calls to this server
VERSION="0.1.0"

# ── Help ──────────────────────────────────────────────────────────────────────
_usage() {
  cat << 'EOF'
uaa — unified-agnostic-api CLI

Usage:
  uaa [--server URL] <adapter> <command> [options]
  uaa server start [--port PORT] [--backend shell2http|cgi|webhook]
  uaa server stop
  uaa adapters list
  uaa health
  uaa version
  uaa help

Adapters:
  filesystem    ls, read, write, stat, mount
  github        repos, releases, permissions, report
  browser       screenshot, scrape, automate
  os            info, processes, clipboard
  ai            complete, shell, bom

Options:
  --server URL  Proxy calls to a running uaa server instead of running locally
  --json        Force JSON output (default for most commands)
  --help, -h    Show this help

Examples:
  uaa filesystem ls --path /tmp
  uaa github repos --org my-org
  uaa ai complete --prompt "explain bash pipelines"
  uaa ai shell --command "list files modified today"
  uaa --server http://localhost:8080 os info
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { _usage; exit 0; }

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --server) UAA_SERVER="$2"; shift 2 ;;
    --help|-h) _usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

ADAPTER="${1:-help}"; shift || true
COMMAND="${1:-}";     [[ $# -gt 0 ]] && shift || true

# ── Server proxy mode ─────────────────────────────────────────────────────────
_proxy() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" \
      -H "Content-Type: application/json" \
      ${UAA_AUTH:+-H "Authorization: Bearer $UAA_AUTH"} \
      -d "$body" \
      "${UAA_SERVER}${path}"
  else
    curl -sf -X "$method" \
      ${UAA_AUTH:+-H "Authorization: Bearer $UAA_AUTH"} \
      "${UAA_SERVER}${path}"
  fi
}

# ── Local adapter dispatch ────────────────────────────────────────────────────
_run_adapter() {
  local script="$1"; shift
  export REPO_ROOT UAA_BACKEND="${UAA_BACKEND:-shell2http}"
  # Parse remaining --key value pairs into v_key env vars (shell2http convention)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*=*) key="${1#--}"; key="${key%%=*}"; val="${1#*=}"; export "v_${key}=${val}"; shift ;;
      --*)   key="${1#--}"; val="${2:-}"; export "v_${key}=${val}"; shift 2 ;;
      *)     break ;;
    esac
  done
  bash "$script"
}

# ── Adapter routing ───────────────────────────────────────────────────────────
case "$ADAPTER" in
  help|--help|-h) _usage; exit 0 ;;
  version)        echo "uaa $VERSION"; exit 0 ;;
  health)
    if [[ -n "$UAA_SERVER" ]]; then _proxy GET /health
    else _run_adapter "$REPO_ROOT/adapters/meta/health.sh" "$@"; fi
    ;;
  adapters)
    if [[ -n "$UAA_SERVER" ]]; then _proxy GET /api/adapters
    else _run_adapter "$REPO_ROOT/adapters/meta/list-adapters.sh" "$@"; fi
    ;;
  server)
    case "$COMMAND" in
      start) exec "$REPO_ROOT/server/start.sh" "$@" ;;
      stop)  pkill -f "shell2http.*${UAA_PORT:-8080}" 2>/dev/null && echo "stopped" || echo "not running" ;;
      *)     error "unknown server command: $COMMAND"; exit 1 ;;
    esac
    ;;
  filesystem|fs)
    case "$COMMAND" in
      ls)    _run_adapter "$REPO_ROOT/adapters/filesystem/ls.sh"    "$@" ;;
      read)  _run_adapter "$REPO_ROOT/adapters/filesystem/read.sh"  "$@" ;;
      write) _run_adapter "$REPO_ROOT/adapters/filesystem/write.sh" "$@" ;;
      stat)  _run_adapter "$REPO_ROOT/adapters/filesystem/stat.sh"  "$@" ;;
      mount) _run_adapter "$REPO_ROOT/adapters/filesystem/mount.sh" "$@" ;;
      *) error "unknown filesystem command: $COMMAND"; exit 1 ;;
    esac
    ;;
  github|gh)
    case "$COMMAND" in
      repos)       _run_adapter "$REPO_ROOT/adapters/github/list-repos.sh"      "$@" ;;
      releases)    _run_adapter "$REPO_ROOT/adapters/github/list-releases.sh"   "$@" ;;
      release)     _run_adapter "$REPO_ROOT/adapters/github/create-release.sh"  "$@" ;;
      permissions) _run_adapter "$REPO_ROOT/adapters/github/bulk-permissions.sh" "$@" ;;
      report)      _run_adapter "$REPO_ROOT/adapters/github/issue-report.sh"    "$@" ;;
      *) error "unknown github command: $COMMAND"; exit 1 ;;
    esac
    ;;
  browser|br)
    case "$COMMAND" in
      screenshot) _run_adapter "$REPO_ROOT/adapters/browser/screenshot.sh" "$@" ;;
      scrape)     _run_adapter "$REPO_ROOT/adapters/browser/scrape.sh"     "$@" ;;
      automate)   _run_adapter "$REPO_ROOT/adapters/browser/automate.sh"   "$@" ;;
      *) error "unknown browser command: $COMMAND"; exit 1 ;;
    esac
    ;;
  os)
    case "$COMMAND" in
      info)      _run_adapter "$REPO_ROOT/adapters/os-compat/system-info.sh"   "$@" ;;
      processes) _run_adapter "$REPO_ROOT/adapters/os-compat/process-list.sh"  "$@" ;;
      clipboard)
        SUB="${1:-get}"; shift || true
        case "$SUB" in
          get) _run_adapter "$REPO_ROOT/adapters/os-compat/clipboard-get.sh" "$@" ;;
          set) _run_adapter "$REPO_ROOT/adapters/os-compat/clipboard-set.sh" "$@" ;;
          *) error "unknown clipboard command: $SUB"; exit 1 ;;
        esac
        ;;
      *) error "unknown os command: $COMMAND"; exit 1 ;;
    esac
    ;;
  ai)
    case "$COMMAND" in
      complete) _run_adapter "$REPO_ROOT/adapters/ai/complete.sh"      "$@" ;;
      shell)    _run_adapter "$REPO_ROOT/adapters/ai/agentic-shell.sh" "$@" ;;
      bom)      _run_adapter "$REPO_ROOT/adapters/ai/bom-scan.sh"      "$@" ;;
      *) error "unknown ai command: $COMMAND"; exit 1 ;;
    esac
    ;;
  *)
    error "unknown adapter: $ADAPTER"
    echo "Run 'uaa help' for usage." >&2
    exit 1
    ;;
esac
