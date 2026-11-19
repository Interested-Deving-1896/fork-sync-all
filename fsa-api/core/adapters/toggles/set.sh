#!/usr/bin/env bash
# POST /api/fsa/toggles/:name
# Enables or disables a named feature toggle in fsa-toggles.yml.
#
# Body (JSON): { "enabled": true|false }
# Route param: :name  (available as ROUTE_name)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

TOGGLE_NAME="${ROUTE_name:-}"
ENABLED="${BODY_enabled:-}"

if [[ -z "$TOGGLE_NAME" ]]; then
  fsa_error "Missing route param: name" 400
  exit 0
fi

if [[ -z "$ENABLED" ]]; then
  fsa_error "Missing required field: enabled (true|false)" 400
  exit 0
fi

TOGGLES_FILE="${_FSA_ROOT}/fsa-api/config/fsa-toggles.yml"

if [[ ! -f "$TOGGLES_FILE" ]]; then
  fsa_error "Toggles config not found: $TOGGLES_FILE" 503
  exit 0
fi

# Validate toggle exists and apply change
result=$(python3 -c "
import json, yaml, sys

with open('${TOGGLES_FILE}') as f:
    cfg = yaml.safe_load(f)

toggles = cfg.get('toggles', {}) or {}
name = '${TOGGLE_NAME}'
enabled = '${ENABLED}'.lower() in ('true', '1', 'yes')

if name not in toggles:
    print(json.dumps({'ok': False, 'error': f'Unknown toggle: {name}', 'status': 404}))
    sys.exit(0)

prev = bool(toggles[name].get('enabled', True))
toggles[name]['enabled'] = enabled
cfg['toggles'] = toggles

with open('${TOGGLES_FILE}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print(json.dumps({
    'ok': True,
    'name': name,
    'previous': prev,
    'enabled': enabled,
    'message': f'Toggle {name} set to {\"enabled\" if enabled else \"disabled\"}',
}))
" 2>/dev/null)

# Surface 404 as HTTP 404
if echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status')==404 else 1)" 2>/dev/null; then
  err=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
  fsa_error "$err" 404
else
  echo "$result"
fi
