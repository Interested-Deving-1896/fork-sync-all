#!/usr/bin/env bash
# scripts/notebooklm-list-backends.sh — print all registered NotebookLM backends
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/../config/notebooklm-backends.yml"

python3 -c "
import yaml, sys
with open('${REGISTRY}') as f:
    cfg = yaml.safe_load(f)
backends = cfg.get('backends', [])
print(f'Registered backends ({len(backends)}):')
print()
for b in backends:
    status = 'enabled' if b.get('enabled') else 'disabled'
    caps = ', '.join(b.get('capabilities', []))
    repo = b.get('repo') or '(closed-source)'
    print(f'  [{status}] {b[\"id\"]}')
    print(f'    name:  {b[\"name\"]}')
    print(f'    type:  {b[\"type\"]}')
    print(f'    repo:  {repo}')
    print(f'    docs:  {b[\"docs_dir\"]}')
    print(f'    caps:  {caps}')
    if b.get('notes'):
        note = b['notes'].strip().replace(chr(10), ' ')[:120]
        print(f'    notes: {note}')
    print()
" 2>/dev/null
