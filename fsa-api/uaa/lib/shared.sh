#!/usr/bin/env bash
# lib/shared.sh — shared logic between UAA and FSA-API
#
# This file is the bidirectional sync point. It contains logic that:
#   - Originated in FSA-API and was generified for UAA consumers
#   - Is useful to any UAA adapter regardless of platform (GitHub, GitLab, etc.)
#
# FSA-API sources this via fsa-api/uaa/lib/shared.sh (symlinked into UAA).
# UAA adapters source it directly as lib/shared.sh.
#
# What lives here (platform-agnostic):
#   - Toggle system: read/check feature toggles from a YAML config
#   - Rate-limit helpers: generic quota check + response (no GitHub coupling)
#   - JSON response helpers: ok/error/list wrappers (mirrors fsa-adapter.sh)
#   - Multi-file route merge: merge_routes_files() for multi-manifest servers
#   - Capability registry: register_capability / list_capabilities
#
# What does NOT live here (stays in fsa-adapter.sh):
#   - GitHub REST/GraphQL API calls (fsa_api_get, fsa_api_post, fsa_graphql)
#   - FSA-specific quota check against api.github.com/rate_limit
#   - FSA org/repo env vars (FSA_ORG, FSA_REPO)

[[ -n "${_UAA_SHARED_LOADED:-}" ]] && return 0
_UAA_SHARED_LOADED=1

# ── Toggle system ─────────────────────────────────────────────────────────────
# Reads a YAML toggles file of the form:
#   toggles:
#     feature_name:
#       enabled: true
#       description: "..."
#
# UAA_TOGGLES_FILE — path to the toggles YAML (set by server or adapter)
UAA_TOGGLES_FILE="${UAA_TOGGLES_FILE:-}"

# toggle_get NAME — prints "enabled", "disabled", or "unknown"
toggle_get() {
  local name="$1"
  local file="${UAA_TOGGLES_FILE:-}"
  [[ -z "$file" || ! -f "$file" ]] && echo "unknown" && return
  python3 -c "
import yaml, sys
with open('${file}') as f:
    cfg = yaml.safe_load(f) or {}
t = cfg.get('toggles', {}).get('${name}')
if t is None:
    print('unknown')
else:
    print('enabled' if t.get('enabled', True) else 'disabled')
" 2>/dev/null || echo "unknown"
}

# toggle_enabled NAME — returns 0 if enabled, 1 if disabled/unknown
toggle_enabled() {
  [[ "$(toggle_get "$1")" == "enabled" ]]
}

# toggle_list — prints all toggles as JSON
toggle_list() {
  local file="${UAA_TOGGLES_FILE:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo '{"ok":true,"toggles":{}}'
    return
  fi
  python3 -c "
import yaml, json
with open('${file}') as f:
    cfg = yaml.safe_load(f) or {}
toggles = cfg.get('toggles', {}) or {}
out = {}
for name, t in toggles.items():
    if isinstance(t, dict):
        out[name] = {'enabled': t.get('enabled', True), 'description': t.get('description', '')}
    else:
        out[name] = {'enabled': bool(t), 'description': ''}
print(json.dumps({'ok': True, 'toggles': out}, indent=2))
" 2>/dev/null || echo '{"ok":false,"error":"failed to read toggles"}'
}

# toggle_set NAME true|false — writes toggle state back to the YAML file
toggle_set() {
  local name="$1" value="$2"
  local file="${UAA_TOGGLES_FILE:-}"
  [[ -z "$file" || ! -f "$file" ]] && return 1
  python3 -c "
import yaml, sys
name, value, path = '${name}', '${value}', '${file}'
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
toggles = cfg.setdefault('toggles', {})
if name not in toggles:
    toggles[name] = {}
if isinstance(toggles[name], dict):
    toggles[name]['enabled'] = (value.lower() == 'true')
else:
    toggles[name] = {'enabled': (value.lower() == 'true')}
with open(path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print('ok')
" 2>/dev/null
}

# ── Generic rate-limit / quota helpers ────────────────────────────────────────
# These are platform-agnostic. Adapters set UAA_QUOTA_REMAINING before calling
# quota_check, or override quota_fetch() to query their platform's rate limit.

UAA_QUOTA_REMAINING="${UAA_QUOTA_REMAINING:-}"

# quota_fetch — override this in platform-specific adapters to populate
# UAA_QUOTA_REMAINING from the platform's rate-limit API.
# Default: returns 9999 (unlimited — safe for platforms without quota).
quota_fetch() {
  echo 9999
}

# quota_check MIN — exits with fsa_error 429 if remaining < MIN.
# Reads UAA_QUOTA_REMAINING if set, otherwise calls quota_fetch().
quota_check() {
  local min="${1:-100}"
  local remaining="${UAA_QUOTA_REMAINING:-}"
  if [[ -z "$remaining" ]]; then
    remaining=$(quota_fetch 2>/dev/null || echo 9999)
    UAA_QUOTA_REMAINING="$remaining"
  fi
  if [[ "$remaining" -lt "$min" ]]; then
    json_error "quota too low: ${remaining} remaining (need ${min})" 429
    return 1
  fi
  return 0
}

# ── JSON response helpers ─────────────────────────────────────────────────────
# Mirrors fsa-adapter.sh helpers so UAA adapters can use the same API.
# These write to stdout (the HTTP response body).

json_ok()    { echo "{\"ok\":true,\"data\":${1:-null}}"; }
json_error() { echo "{\"ok\":false,\"error\":\"${1:-error}\",\"code\":${2:-500}}"; }
json_list()  {
  local items="$1"
  local count
  count=$(echo "$items" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  echo "{\"ok\":true,\"count\":${count},\"items\":${items}}"
}

# ── Multi-file route merge ────────────────────────────────────────────────────
# merge_routes_files FILE1 [FILE2 ...] — merges multiple routes.yml files
# into a single combined manifest, deduplicating by path+method.
# Prints the merged YAML to stdout.
merge_routes_files() {
  python3 - "$@" << 'PYEOF'
import yaml, sys, os

files = sys.argv[1:]
seen = {}   # (path, method) -> route — last writer wins
ordered = []

for fpath in files:
    if not os.path.isfile(fpath):
        print(f"[shared] routes file not found: {fpath}", file=sys.stderr)
        continue
    with open(fpath) as f:
        cfg = yaml.safe_load(f) or {}
    for route in cfg.get('routes', []):
        key = (route.get('path', ''), route.get('method', 'GET').upper())
        if key not in seen:
            ordered.append(key)
        seen[key] = route

merged = {'routes': [seen[k] for k in ordered]}
print(yaml.dump(merged, default_flow_style=False, allow_unicode=True, sort_keys=False), end='')
PYEOF
}

# ── Capability registry ───────────────────────────────────────────────────────
# Lightweight in-memory registry for adapter self-description.
# Adapters call register_capability at load time; /api/adapters reads it.

declare -A _UAA_CAPABILITIES 2>/dev/null || true

# register_capability NAME DESCRIPTION [VERSION]
register_capability() {
  local name="$1" desc="$2" ver="${3:-0.1.0}"
  _UAA_CAPABILITIES["$name"]=$(python3 -c "
import json
print(json.dumps({'name': '$name', 'description': '$desc', 'version': '$ver'}))
" 2>/dev/null || echo "{\"name\":\"$name\"}")
}

# list_capabilities — prints all registered capabilities as JSON array
list_capabilities() {
  local items="["
  local first=1
  for key in "${!_UAA_CAPABILITIES[@]}"; do
    [[ "$first" == "1" ]] || items+=","
    items+="${_UAA_CAPABILITIES[$key]}"
    first=0
  done
  items+="]"
  echo "$items"
}
