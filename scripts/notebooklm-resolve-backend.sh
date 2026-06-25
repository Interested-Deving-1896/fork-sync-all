#!/usr/bin/env bash
# scripts/notebooklm-resolve-backend.sh — resolve backend config and write GITHUB_OUTPUT
#
# Reads BACKEND_ID from env, looks it up in config/notebooklm-backends.yml,
# and writes backend_name, backend_type, docs_dir, capabilities to GITHUB_OUTPUT.
#
# Usage (in workflow step):
#   env:
#     BACKEND_ID: ${{ inputs.backend }}
#   run: bash scripts/notebooklm-resolve-backend.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/../config/notebooklm-backends.yml"
BACKEND_ID="${BACKEND_ID:-google-notebooklm}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

python3 -c "
import yaml, sys, os
with open('${REGISTRY}') as f:
    cfg = yaml.safe_load(f)
backends = {b['id']: b for b in cfg.get('backends', [])}
b = backends.get('${BACKEND_ID}')
if not b:
    print('::error::Unknown backend: ${BACKEND_ID}', file=sys.stderr)
    print('Available backends: ' + ', '.join(backends.keys()), file=sys.stderr)
    sys.exit(1)
if not b.get('enabled', True):
    print('::error::Backend ${BACKEND_ID} is disabled in config/notebooklm-backends.yml', file=sys.stderr)
    sys.exit(1)
out = '${OUTPUT}'
with open(out, 'a') as fh:
    fh.write('backend_name=' + b['name'] + '\n')
    fh.write('backend_type=' + b['type'] + '\n')
    fh.write('docs_dir=' + b['docs_dir'] + '\n')
    fh.write('capabilities=' + ','.join(b.get('capabilities', [])) + '\n')
print(f'Backend resolved: {b[\"name\"]} ({b[\"type\"]}) -> {b[\"docs_dir\"]}')
" 2>&1
