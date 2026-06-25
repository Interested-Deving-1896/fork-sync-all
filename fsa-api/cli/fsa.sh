#!/usr/bin/env bash
# fsa-api/cli/fsa.sh — FSA API command-line client
#
# Talks to a running fsa-start.sh server (or directly to GitHub when --direct).
#
# Usage:
#   fsa <resource> <subcommand> [options]
#
# Resources:
#   workflows   list | run <name> | status <name>
#   repos       list | onboard <name>
#   notifications list | triage
#   quota       status
#   chain       status | flush
#   toggles     list | set <name> <true|false>
#   server      start | stop | status
#
# Options:
#   --api URL       FSA API base URL (default: $FSA_API_URL or http://localhost:8090)
#   --token TOKEN   Bearer token for auth-gated endpoints (default: $FSA_AUTH)
#   --dry-run       Pass dry_run=true to mutating endpoints
#   --json          Raw JSON output (default: pretty-printed)
#   --help, -h      Show this help
#
# Environment:
#   FSA_API_URL  — base URL of the FSA API server
#   FSA_AUTH     — bearer token for auth-gated endpoints
#   GH_TOKEN     — used when --direct is set (bypasses the API server)

set -euo pipefail

FSA_API_URL="${FSA_API_URL:-http://localhost:8090}"
FSA_AUTH="${FSA_AUTH:-}"
DRY_RUN="false"
JSON_RAW="false"
DIRECT="false"

# ── Helpers ───────────────────────────────────────────────────────────────────
_die()  { echo "[fsa] error: $*" >&2; exit 1; }
_info() { echo "[fsa] $*" >&2; }

_usage() {
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
}

_pretty() {
  if [[ "$JSON_RAW" == "true" ]]; then
    cat
  else
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(json.dumps(d, indent=2))
except Exception:
    sys.stdin.seek(0)
    print(sys.stdin.read())
" 2>/dev/null || cat
  fi
}

_curl_get() {
  local path="$1"; shift
  local args=()
  [[ -n "$FSA_AUTH" ]] && args+=(-H "Authorization: Bearer $FSA_AUTH")
  curl -sf "${FSA_API_URL}${path}" "${args[@]}" "$@"
}

_curl_post() {
  local path="$1"; shift
  local body="${1:-{}}"
  local args=(-X POST -H "Content-Type: application/json" -d "$body")
  [[ -n "$FSA_AUTH" ]] && args+=(-H "Authorization: Bearer $FSA_AUTH")
  curl -sf "${FSA_API_URL}${path}" "${args[@]}"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api)      FSA_API_URL="$2"; shift 2 ;;
    --token)    FSA_AUTH="$2";    shift 2 ;;
    --dry-run)  DRY_RUN="true";   shift ;;
    --json)     JSON_RAW="true";  shift ;;
    --direct)   DIRECT="true";    shift ;;
    --help|-h)  _usage ;;
    *)          POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

RESOURCE="${1:-}"
SUBCOMMAND="${2:-}"

[[ -z "$RESOURCE" ]] && _usage

# ── Resource dispatch ─────────────────────────────────────────────────────────

case "$RESOURCE" in

  # ── workflows ───────────────────────────────────────────────────────────────
  workflows)
    case "$SUBCOMMAND" in
      list)
        STATUS="${3:-}"
        LIMIT="${4:-20}"
        QS="?limit=${LIMIT}"
        [[ -n "$STATUS" ]] && QS="${QS}&status=${STATUS}"
        _curl_get "/api/fsa/workflows${QS}" | _pretty
        ;;
      run)
        NAME="${3:-}"; [[ -z "$NAME" ]] && _die "usage: fsa workflows run <name> [ref]"
        REF="${4:-main}"
        BODY="{\"ref\":\"${REF}\",\"dry_run\":${DRY_RUN}}"
        _curl_post "/api/fsa/workflows/${NAME}/run" "$BODY" | _pretty
        ;;
      status)
        NAME="${3:-}"; [[ -z "$NAME" ]] && _die "usage: fsa workflows status <name>"
        LIMIT="${4:-5}"
        _curl_get "/api/fsa/workflows/${NAME}/status?limit=${LIMIT}" | _pretty
        ;;
      *) _die "unknown subcommand: workflows ${SUBCOMMAND}. Valid: list | run | status" ;;
    esac
    ;;

  # ── repos ────────────────────────────────────────────────────────────────────
  repos)
    case "$SUBCOMMAND" in
      list)
        TYPE="${3:-all}"
        FILTER="${4:-}"
        QS="?type=${TYPE}"
        [[ -n "$FILTER" ]] && QS="${QS}&filter=${FILTER}"
        _curl_get "/api/fsa/repos${QS}" | _pretty
        ;;
      onboard)
        NAME="${3:-}"; [[ -z "$NAME" ]] && _die "usage: fsa repos onboard <repo-name>"
        BODY="{\"repo\":\"${NAME}\",\"dry_run\":${DRY_RUN}}"
        _curl_post "/api/fsa/repos/onboard" "$BODY" | _pretty
        ;;
      *) _die "unknown subcommand: repos ${SUBCOMMAND}. Valid: list | onboard" ;;
    esac
    ;;

  # ── notifications ────────────────────────────────────────────────────────────
  notifications|notifs|n)
    case "$SUBCOMMAND" in
      list|"")
        SCOPE="${3:-all}"
        LIMIT="${4:-50}"
        _curl_get "/api/fsa/notifications?scope=${SCOPE}&limit=${LIMIT}" | _pretty
        ;;
      triage)
        BODY="{\"dry_run\":${DRY_RUN}}"
        _curl_post "/api/fsa/notifications/triage" "$BODY" | _pretty
        ;;
      *) _die "unknown subcommand: notifications ${SUBCOMMAND}. Valid: list | triage" ;;
    esac
    ;;

  # ── quota ────────────────────────────────────────────────────────────────────
  quota|q)
    _curl_get "/api/fsa/quota" | _pretty
    ;;

  # ── chain ────────────────────────────────────────────────────────────────────
  chain)
    case "$SUBCOMMAND" in
      status|"")
        _curl_get "/api/fsa/chain/status" | _pretty
        ;;
      flush)
        FORCE="${3:-false}"
        BODY="{\"dry_run\":${DRY_RUN},\"force\":${FORCE}}"
        _curl_post "/api/fsa/chain/flush" "$BODY" | _pretty
        ;;
      *) _die "unknown subcommand: chain ${SUBCOMMAND}. Valid: status | flush" ;;
    esac
    ;;

  # ── toggles ──────────────────────────────────────────────────────────────────
  toggles|toggle|t)
    case "$SUBCOMMAND" in
      list|"")
        _curl_get "/api/fsa/toggles" | _pretty
        ;;
      set)
        NAME="${3:-}";    [[ -z "$NAME" ]]    && _die "usage: fsa toggles set <name> <true|false>"
        ENABLED="${4:-}"; [[ -z "$ENABLED" ]] && _die "usage: fsa toggles set <name> <true|false>"
        [[ "$ENABLED" != "true" && "$ENABLED" != "false" ]] && _die "enabled must be true or false"
        BODY="{\"enabled\":${ENABLED}}"
        _curl_post "/api/fsa/toggles/${NAME}" "$BODY" | _pretty
        ;;
      *) _die "unknown subcommand: toggles ${SUBCOMMAND}. Valid: list | set" ;;
    esac
    ;;

  # ── server ───────────────────────────────────────────────────────────────────
  server)
    FSA_API_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    case "$SUBCOMMAND" in
      start)
        _info "starting FSA API server on ${FSA_API_URL}..."
        exec "$FSA_API_ROOT/server/fsa-start.sh" "$@"
        ;;
      stop)
        PID=$(pgrep -f "fsa-start.sh" 2>/dev/null || true)
        if [[ -z "$PID" ]]; then
          _info "no running fsa-start.sh found"
        else
          kill "$PID" && _info "stopped PID $PID"
        fi
        ;;
      status)
        if pgrep -f "fsa-start.sh" &>/dev/null; then
          _info "server running (PID $(pgrep -f 'fsa-start.sh'))"
          _curl_get "/health" 2>/dev/null | _pretty || _info "(health check failed)"
        else
          _info "server not running"
        fi
        ;;
      *) _die "unknown subcommand: server ${SUBCOMMAND}. Valid: start | stop | status" ;;
    esac
    ;;

  *)
    _die "unknown resource: $RESOURCE. Valid: workflows | repos | notifications | quota | chain | toggles | server"
    ;;
esac
