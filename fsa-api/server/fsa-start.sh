#!/usr/bin/env bash
# fsa-api/server/fsa-start.sh — FSA API server
#
# Merges UAA base routes (fsa-api/uaa/config/routes.yml) with FSA-specific
# routes (fsa-api/config/fsa-routes.yml), applies toggle filtering, then
# delegates to the UAA backend (shell2http | cgi | webhook).
#
# Usage:
#   ./fsa-api/server/fsa-start.sh [--port PORT] [--host HOST] [--backend BACKEND]
#   FSA_PORT=9090 ./fsa-api/server/fsa-start.sh
#
# Environment:
#   FSA_PORT     — listen port (default: 8090)
#   FSA_HOST     — listen host (default: 0.0.0.0)
#   FSA_BACKEND  — http backend: shell2http | cgi | webhook (default: shell2http)
#   FSA_LOG      — log level: debug | info | warn (default: info)
#   FSA_AUTH     — bearer token for auth-gated routes (optional)
#   GH_TOKEN     — GitHub token for FSA adapter calls (required)
#   FSA_ORG      — GitHub org (default: Interested-Deving-1896)
#   FSA_REPO     — control-plane repo (default: fork-sync-all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSA_API_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UAA_ROOT="$FSA_API_ROOT/uaa"

# Source UAA libs (log + routes)
source "$UAA_ROOT/lib/log.sh"
source "$UAA_ROOT/lib/routes.sh"

FSA_PORT="${FSA_PORT:-8090}"
FSA_HOST="${FSA_HOST:-0.0.0.0}"
FSA_BACKEND="${FSA_BACKEND:-shell2http}"
FSA_LOG="${FSA_LOG:-info}"
FSA_ORG="${FSA_ORG:-Interested-Deving-1896}"
FSA_REPO="${FSA_REPO:-fork-sync-all}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    FSA_PORT="$2";    shift 2 ;;
    --host)    FSA_HOST="$2";    shift 2 ;;
    --backend) FSA_BACKEND="$2"; shift 2 ;;
    --log)     FSA_LOG="$2";     shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) warn "unknown argument: $1"; shift ;;
  esac
done

export FSA_PORT FSA_HOST FSA_LOG FSA_ORG FSA_REPO FSA_API_ROOT UAA_ROOT
# UAA libs use REPO_ROOT; point it at the FSA API root so relative script
# paths in fsa-routes.yml resolve correctly.
export REPO_ROOT="$FSA_API_ROOT"

# ── Validate required env ─────────────────────────────────────────────────────
if [[ -z "${GH_TOKEN:-}" ]]; then
  error "GH_TOKEN is required for FSA adapter calls"
  exit 1
fi

# ── Merge route manifests ─────────────────────────────────────────────────────
UAA_ROUTES="$UAA_ROOT/config/routes.yml"
FSA_ROUTES="$FSA_API_ROOT/config/fsa-routes.yml"
FSA_TOGGLES="$FSA_API_ROOT/config/fsa-toggles.yml"
MERGED_ROUTES="/tmp/fsa-merged-routes-$$.yml"

[[ -f "$UAA_ROUTES" ]] || { error "UAA routes not found: $UAA_ROUTES"; exit 1; }
[[ -f "$FSA_ROUTES" ]] || { error "FSA routes not found: $FSA_ROUTES"; exit 1; }
[[ -f "$FSA_TOGGLES" ]] || { error "FSA toggles not found: $FSA_TOGGLES"; exit 1; }

python3 - "$UAA_ROUTES" "$FSA_ROUTES" "$FSA_TOGGLES" "$MERGED_ROUTES" << 'PYEOF'
import yaml, sys

uaa_file, fsa_file, toggles_file, out_file = sys.argv[1:]

with open(uaa_file) as f:
    uaa_cfg = yaml.safe_load(f)
with open(fsa_file) as f:
    fsa_cfg = yaml.safe_load(f)
with open(toggles_file) as f:
    tgl_cfg = yaml.safe_load(f)

toggles = tgl_cfg.get('toggles', {}) or {}

uaa_routes = uaa_cfg.get('routes', []) or []
fsa_routes = fsa_cfg.get('routes', []) or []

# Filter FSA routes by toggle state
active_fsa = []
for route in fsa_routes:
    toggle_name = route.get('toggle')
    if toggle_name:
        t = toggles.get(toggle_name, {})
        if not t.get('enabled', True):
            print(f"[fsa-start] toggle '{toggle_name}' disabled — skipping {route.get('path')}", file=sys.stderr)
            continue
    active_fsa.append(route)

merged = {'routes': uaa_routes + active_fsa}
with open(out_file, 'w') as f:
    yaml.dump(merged, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

total = len(uaa_routes) + len(active_fsa)
print(f"[fsa-start] merged {len(uaa_routes)} UAA + {len(active_fsa)} FSA routes ({total} total)", file=sys.stderr)
PYEOF

trap 'rm -f "$MERGED_ROUTES"' EXIT

info "FSA API server starting"
info "  backend : $FSA_BACKEND"
info "  listen  : $FSA_HOST:$FSA_PORT"
info "  org     : $FSA_ORG / $FSA_REPO"
info "  root    : $FSA_API_ROOT"

# ── Backend dispatch ──────────────────────────────────────────────────────────
case "$FSA_BACKEND" in
  shell2http)
    if ! command -v shell2http &>/dev/null; then
      error "shell2http not found. Install: go install github.com/msoap/shell2http@latest"
      exit 1
    fi
    mapfile -t ROUTE_ARGS < <(routes_to_shell2http_args "$MERGED_ROUTES")
    info "registering ${#ROUTE_ARGS[@]} route arg(s)"
    exec shell2http \
      -host "$FSA_HOST" \
      -port "$FSA_PORT" \
      -log \
      "${ROUTE_ARGS[@]}"
    ;;

  cgi)
    CGI_DIR="${CGI_DIR:-/usr/lib/cgi-bin/fsa}"
    info "deploying CGI scripts to $CGI_DIR"
    "$UAA_ROOT/server/deploy-cgi.sh" "$CGI_DIR" "$MERGED_ROUTES"
    info "CGI deployed. Configure Apache to serve $CGI_DIR on port $FSA_PORT."
    ;;

  webhook)
    if ! command -v webhook &>/dev/null; then
      error "webhook not found. Install: go install github.com/adnanh/webhook@latest"
      exit 1
    fi
    HOOKS_FILE="/tmp/fsa-hooks-$$.json"
    trap 'rm -f "$MERGED_ROUTES" "$HOOKS_FILE"' EXIT
    routes_to_hooks_json "$MERGED_ROUTES" > "$HOOKS_FILE"
    exec webhook \
      -hooks "$HOOKS_FILE" \
      -port "$FSA_PORT" \
      -ip "$FSA_HOST" \
      -verbose
    ;;

  *)
    error "unknown backend: $FSA_BACKEND (valid: shell2http | cgi | webhook)"
    exit 1
    ;;
esac
