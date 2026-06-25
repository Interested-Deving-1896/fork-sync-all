#!/usr/bin/env bash
# GET /api/fsa/toggles
# Lists all feature toggles and their current state from fsa-toggles.yml.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

TOGGLES_FILE="${_FSA_ROOT}/fsa-api/config/fsa-toggles.yml"

if [[ ! -f "$TOGGLES_FILE" ]]; then
  fsa_error "Toggles config not found: $TOGGLES_FILE" 503
  exit 0
fi

python3 -c "
import json, yaml, sys

with open('${TOGGLES_FILE}') as f:
    cfg = yaml.safe_load(f)

toggles = cfg.get('toggles', {}) or {}
items = []
for name, meta in sorted(toggles.items()):
    items.append({
        'name': name,
        'enabled': bool(meta.get('enabled', True)),
        'description': meta.get('description', ''),
        'affects': meta.get('affects', []),
    })

print(json.dumps({
    'ok': True,
    'count': len(items),
    'items': items,
}, indent=2))
" 2>/dev/null
