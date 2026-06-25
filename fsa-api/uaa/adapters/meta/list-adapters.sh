#!/usr/bin/env bash
# adapters/meta/list-adapters.sh — list all registered adapters
# GET /api/adapters
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

# Discover all adapter manifests
python3 - "$REPO_ROOT/adapters" "$REPO_ROOT/config/routes.yml" << 'PYEOF'
import os, yaml, json, sys

adapters_dir, routes_file = sys.argv[1], sys.argv[2]
with open(routes_file) as f:
    config = yaml.safe_load(f)

# Group routes by adapter directory
adapters = {}
for route in config.get('routes', []):
    script = route.get('script', '')
    parts = script.split('/')
    if len(parts) >= 2:
        adapter = parts[1]  # adapters/<adapter>/script.sh
        if adapter not in adapters:
            adapters[adapter] = []
        adapters[adapter].append({
            "path": route.get('path'),
            "method": route.get('method', 'GET'),
            "auth": route.get('auth', False)
        })

result = []
for name, routes in sorted(adapters.items()):
    manifest_path = os.path.join(adapters_dir, name, 'manifest.yml')
    desc = ''
    if os.path.isfile(manifest_path):
        with open(manifest_path) as f:
            m = yaml.safe_load(f) or {}
        desc = m.get('description', '')
    result.append({"adapter": name, "description": desc, "routes": routes})

print(json.dumps({"adapters": result}, indent=2))
PYEOF
