#!/usr/bin/env bash
# server/start.sh — unified-agnostic-api HTTP server
#
# Starts the API server using shell2http (preferred) or falls back to the
# bash-api-server CGI pattern if shell2http is not installed.
#
# Usage:
#   ./server/start.sh [--port PORT] [--host HOST] [--backend shell2http|cgi]
#   UAA_PORT=9090 ./server/start.sh
#
# Environment:
#   UAA_PORT     — listen port (default: 8080)
#   UAA_HOST     — listen host (default: 0.0.0.0)
#   UAA_BACKEND  — http backend: shell2http | cgi (default: shell2http)
#   UAA_LOG      — log level: debug | info | warn (default: info)
#   UAA_AUTH     — bearer token for auth (optional; disables auth if unset)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/routes.sh
source "$REPO_ROOT/lib/routes.sh"

UAA_PORT="${UAA_PORT:-8080}"
UAA_HOST="${UAA_HOST:-0.0.0.0}"
UAA_BACKEND="${UAA_BACKEND:-shell2http}"
UAA_LOG="${UAA_LOG:-info}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    UAA_PORT="$2";    shift 2 ;;
    --host)    UAA_HOST="$2";    shift 2 ;;
    --backend) UAA_BACKEND="$2"; shift 2 ;;
    --log)     UAA_LOG="$2";     shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) warn "unknown argument: $1"; shift ;;
  esac
done

export UAA_PORT UAA_HOST UAA_LOG REPO_ROOT

info "unified-agnostic-api server starting"
info "  backend : $UAA_BACKEND"
info "  listen  : $UAA_HOST:$UAA_PORT"
info "  root    : $REPO_ROOT"

# ── Load route manifest ───────────────────────────────────────────────────────
ROUTES_FILE="$REPO_ROOT/config/routes.yml"
[[ -f "$ROUTES_FILE" ]] || { error "config/routes.yml not found"; exit 1; }

# ── Backend dispatch ──────────────────────────────────────────────────────────
case "$UAA_BACKEND" in
  shell2http)
    if ! command -v shell2http &>/dev/null; then
      error "shell2http not found. Install: go install github.com/msoap/shell2http@latest"
      error "Or set UAA_BACKEND=cgi to use the Apache CGI fallback."
      exit 1
    fi
    # Build shell2http route args from routes.yml
    mapfile -t ROUTE_ARGS < <(routes_to_shell2http_args "$ROUTES_FILE")
    info "registering ${#ROUTE_ARGS[@]} route(s)"
    exec shell2http \
      -host "$UAA_HOST" \
      -port "$UAA_PORT" \
      -log \
      "${ROUTE_ARGS[@]}"
    ;;

  cgi)
    # Fallback: Apache CGI mode (bash-api-server pattern)
    # Requires Apache with mod_cgi enabled and CGI_DIR configured.
    CGI_DIR="${CGI_DIR:-/usr/lib/cgi-bin/uaa}"
    info "deploying CGI scripts to $CGI_DIR"
    "$SCRIPT_DIR/deploy-cgi.sh" "$CGI_DIR"
    info "CGI deployed. Configure Apache to serve $CGI_DIR on port $UAA_PORT."
    ;;

  webhook)
    if ! command -v webhook &>/dev/null; then
      error "webhook not found. Install: go install github.com/adnanh/webhook@latest"
      exit 1
    fi
    HOOKS_FILE="$REPO_ROOT/config/hooks.json"
    [[ -f "$HOOKS_FILE" ]] || { error "config/hooks.json not found"; exit 1; }
    exec webhook \
      -hooks "$HOOKS_FILE" \
      -port "$UAA_PORT" \
      -ip "$UAA_HOST" \
      -verbose
    ;;

  *)
    error "unknown backend: $UAA_BACKEND (valid: shell2http | cgi | webhook)"
    exit 1
    ;;
esac
