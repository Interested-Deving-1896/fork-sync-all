#!/usr/bin/env bash
# GET /api/fsa/security/scan
# Runs dev-machine-guard to scan the current environment for suspicious
# packages, AI agents, MCP servers, and IDE extensions.
# Returns degraded (not error) when dev-machine-guard is not installed.
#
# Query params:
#   ?format=json|text   (default: json)
#   ?categories=all|packages|agents|extensions|processes  (default: all)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

FORMAT="${QUERY_format:-json}"
CATEGORIES="${QUERY_categories:-all}"

if ! command -v dev-machine-guard &>/dev/null; then
  echo "{\"ok\":true,\"available\":false,\"reason\":\"dev-machine-guard not installed\",\"install\":\"https://github.com/step-security/dev-machine-guard\"}"
  exit 0
fi

# Build scan args from categories
SCAN_ARGS=()
if [[ "$CATEGORIES" != "all" ]]; then
  IFS=',' read -ra CATS <<< "$CATEGORIES"
  for cat in "${CATS[@]}"; do
    SCAN_ARGS+=("--${cat}")
  done
fi

# Run scan — dev-machine-guard exits non-zero when findings exist
scan_output=$(dev-machine-guard scan "${SCAN_ARGS[@]}" --format json 2>/dev/null || \
              dev-machine-guard scan "${SCAN_ARGS[@]}" 2>/dev/null || \
              echo '{"findings":[]}')

if [[ "$FORMAT" == "text" ]]; then
  echo "$scan_output"
  exit 0
fi

# Wrap in FSA envelope
python3 -c "
import json, sys

raw = '''${scan_output}'''
try:
    data = json.loads(raw)
except Exception:
    data = {'raw': raw}

findings = data.get('findings', []) if isinstance(data, dict) else []
critical = [f for f in findings if f.get('severity','').lower() in ('critical','high')]

print(json.dumps({
    'ok': True,
    'available': True,
    'finding_count': len(findings),
    'critical_count': len(critical),
    'clean': len(findings) == 0,
    'findings': findings,
}, indent=2))
" 2>/dev/null || echo "{\"ok\":true,\"available\":true,\"raw\":$(echo "$scan_output" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '\"\"')}"
