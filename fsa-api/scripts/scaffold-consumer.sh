#!/usr/bin/env bash
# fsa-api/scripts/scaffold-consumer.sh — generate a branded consumer API layer
#
# Creates fsa-api/consumer/ with the directory structure, starter routes,
# starter toggles, a lib stub, and an example adapter — ready to customise.
#
# Usage:
#   bash fsa-api/scripts/scaffold-consumer.sh <brand-name> [api-prefix]
#
# Examples:
#   bash fsa-api/scripts/scaffold-consumer.sh "MyOrg Sync" myorg
#   bash fsa-api/scripts/scaffold-consumer.sh "OpenOS Control" ooc

set -euo pipefail

BRAND="${1:-}"
PREFIX="${2:-}"

if [[ -z "$BRAND" ]]; then
  echo "Usage: $0 <brand-name> [api-prefix]" >&2
  exit 1
fi

# Derive prefix from brand if not given
if [[ -z "$PREFIX" ]]; then
  PREFIX=$(echo "$BRAND" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSA_API_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSUMER_ROOT="$FSA_API_ROOT/consumer"

echo "[scaffold] brand   : $BRAND" >&2
echo "[scaffold] prefix  : $PREFIX" >&2
echo "[scaffold] output  : $CONSUMER_ROOT" >&2

# ── Directory structure ───────────────────────────────────────────────────────
mkdir -p \
  "$CONSUMER_ROOT/adapters/meta" \
  "$CONSUMER_ROOT/adapters/status" \
  "$CONSUMER_ROOT/config" \
  "$CONSUMER_ROOT/lib"

# ── Consumer routes ───────────────────────────────────────────────────────────
cat > "$CONSUMER_ROOT/config/routes.yml" << YAML
# fsa-api/consumer/config/routes.yml — ${BRAND} API route manifest
#
# Routes are served under /api/${PREFIX}/... alongside the FSA control-plane
# routes (/api/fsa/...) when consumer.serve_alongside_fsa: true.
#
# Add your own adapters under fsa-api/consumer/adapters/ and register them here.

routes:

  # ── Meta ────────────────────────────────────────────────────────────────────
  - path: /api/${PREFIX}/health
    script: consumer/adapters/meta/health.sh
    method: GET

  - path: /api/${PREFIX}/status
    script: consumer/adapters/status/overview.sh
    method: GET

  # ── Add your routes below ───────────────────────────────────────────────────
  # - path: /api/${PREFIX}/my-resource
  #   script: consumer/adapters/my-resource/list.sh
  #   method: GET
  #   toggle: my_toggle
YAML

# ── Consumer toggles ──────────────────────────────────────────────────────────
cat > "$CONSUMER_ROOT/config/toggles.yml" << YAML
# fsa-api/consumer/config/toggles.yml — ${BRAND} feature toggles
#
# Add toggles here to gate consumer routes without removing them.

toggles:
  # example_feature:
  #   enabled: true
  #   description: Example consumer feature
  #   affects:
  #     - /api/${PREFIX}/my-resource
YAML

# ── Consumer lib stub ─────────────────────────────────────────────────────────
cat > "$CONSUMER_ROOT/lib/consumer-adapter.sh" << 'BASH'
#!/usr/bin/env bash
# fsa-api/consumer/lib/consumer-adapter.sh — consumer adapter helpers
#
# Sources fsa-adapter.sh (which sources UAA adapter.sh) so consumer adapters
# get the full FSA + UAA helper set, then adds consumer-specific helpers.

[[ -n "${_CONSUMER_ADAPTER_LOADED:-}" ]] && return 0
_CONSUMER_ADAPTER_LOADED=1

_CONSUMER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CONSUMER_LIB/../../core/lib/fsa-adapter.sh"

# Consumer brand / prefix (set from fsa-consumer.yml at server start)
CONSUMER_BRAND="${CONSUMER_BRAND:-}"
CONSUMER_PREFIX="${CONSUMER_PREFIX:-}"

consumer_info() { echo "[${CONSUMER_BRAND:-consumer}] $*" >&2; }
consumer_error() {
  local msg="$1" code="${2:-500}"
  echo "{\"ok\":false,\"error\":\"${msg}\",\"brand\":\"${CONSUMER_BRAND:-}\"}"
  exit 0
}
BASH

# ── Meta health adapter ───────────────────────────────────────────────────────
cat > "$CONSUMER_ROOT/adapters/meta/health.sh" << BASH
#!/usr/bin/env bash
# GET /api/${PREFIX}/health
source "\$(dirname "\${BASH_SOURCE[0]}")/../../lib/consumer-adapter.sh"

echo '{"ok":true,"brand":"${BRAND}","prefix":"${PREFIX}","status":"healthy"}'
BASH

# ── Status overview adapter ───────────────────────────────────────────────────
cat > "$CONSUMER_ROOT/adapters/status/overview.sh" << BASH
#!/usr/bin/env bash
# GET /api/${PREFIX}/status
# Returns a summary of the consumer deployment's FSA quota + chain state.
source "\$(dirname "\${BASH_SOURCE[0]}")/../../lib/consumer-adapter.sh"

fsa_quota_check 10 || exit 0

quota=\$(bash "\${_FSA_ROOT}/fsa-api/core/adapters/quota/status.sh" 2>/dev/null || echo '{}')
chain=\$(bash "\${_FSA_ROOT}/fsa-api/core/adapters/chain/status.sh" 2>/dev/null || echo '{}')

python3 -c "
import json, sys
quota = json.loads('''${quota}''') if '''${quota}''' != '{}' else {}
chain = json.loads('''${chain}''') if '''${chain}''' != '{}' else {}
print(json.dumps({
    'ok': True,
    'brand': '${BRAND}',
    'prefix': '${PREFIX}',
    'quota': quota,
    'chain': chain,
}, indent=2))
" 2>/dev/null || echo '{"ok":true,"brand":"${BRAND}","prefix":"${PREFIX}"}'
BASH

chmod +x \
  "$CONSUMER_ROOT/adapters/meta/health.sh" \
  "$CONSUMER_ROOT/adapters/status/overview.sh" \
  "$CONSUMER_ROOT/lib/consumer-adapter.sh"

# ── Update fsa-consumer.yml ───────────────────────────────────────────────────
CONSUMER_CFG="$FSA_API_ROOT/config/fsa-consumer.yml"
python3 - "$CONSUMER_CFG" "$BRAND" "$PREFIX" << 'PYEOF'
import yaml, sys

cfg_file, brand, prefix = sys.argv[1:]
with open(cfg_file) as f:
    cfg = yaml.safe_load(f)

cfg['consumer'] = {
    'enabled': True,
    'brand': brand,
    'api_prefix': prefix,
    'port': 8091,
    'routes_file': 'fsa-api/consumer/config/routes.yml',
    'toggles_file': 'fsa-api/consumer/config/toggles.yml',
    'adapters_root': 'fsa-api/consumer/adapters',
    'serve_alongside_fsa': True,
    'auth_required': False,
}

with open(cfg_file, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print(f"[scaffold] updated fsa-consumer.yml: enabled=true brand='{brand}' prefix='{prefix}'", file=sys.stderr)
PYEOF

echo "[scaffold] done. Next steps:" >&2
echo "  1. Add routes to $CONSUMER_ROOT/config/routes.yml" >&2
echo "  2. Add adapters under $CONSUMER_ROOT/adapters/" >&2
echo "  3. Run: fsa-api/server/fsa-start.sh (consumer routes served alongside FSA)" >&2
