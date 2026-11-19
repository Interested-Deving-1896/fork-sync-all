#!/usr/bin/env bash
# GET /api/fsa/docs
# Lists all docs/publishing workflows with their last run status and dispatch URL.
#
# Query params:
#   ?category=all|book|readme|translate|sbom|notebooklm  (default: all)
#   ?status=all|success|failure|in_progress               (default: all)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

CATEGORY="${QUERY_category:-all}"
STATUS_FILTER="${QUERY_status:-all}"

fsa_quota_check 50 || exit 0

python3 - << PYEOF
import yaml, os, json

repo_root = '${_FSA_ROOT}'
wf_dir = os.path.join(repo_root, '.github/workflows')

# Docs workflow categories
CATEGORIES = {
    'book':        ['book-export', 'deploy-book', 'generate-book-pages', 'update-book-index',
                    'sync-eggs-docs-to-book', 'gitbook-oss'],
    'readme':      ['create-readmes', 'update-readmes', 'lts-readmes', 'readme-wizard',
                    'validate-readme-render', 'translate-readmes', 'trigger-readme-update'],
    'translate':   ['translate-docs', 'translate-readmes'],
    'sbom':        ['generate-sbom'],
    'notebooklm':  ['generate-notebooklm', 'refresh-notebooklm-auth', 'upload-notebooklm'],
    'publish':     ['deploy-book', 'gitbook-oss'],
    'generate':    ['generate-book-pages', 'generate-dep-graph', 'generate-notebooklm',
                    'generate-repo-descriptions', 'generate-sbom', 'update-workflow-triggers-doc'],
}

# All docs workflow stems
ALL_DOC_STEMS = set()
for stems in CATEGORIES.values():
    ALL_DOC_STEMS.update(stems)

category = '${CATEGORY}'
results = []

for fname in sorted(os.listdir(wf_dir)):
    if not fname.endswith(('.yml', '.yaml')):
        continue
    stem = fname.replace('.yml', '').replace('.yaml', '')
    if stem not in ALL_DOC_STEMS:
        continue

    # Determine categories for this workflow
    wf_categories = [cat for cat, stems in CATEGORIES.items() if stem in stems]

    if category != 'all' and category not in wf_categories:
        continue

    path = os.path.join(wf_dir, fname)
    try:
        with open(path) as f:
            d = yaml.safe_load(f)
        name = d.get('name', fname)
        on = d.get(True, d.get('on', {})) or {}
        if isinstance(on, str): on = {on: {}}
        has_dispatch = 'workflow_dispatch' in on
        inputs = {}
        if has_dispatch:
            wd = on.get('workflow_dispatch') or {}
            if isinstance(wd, dict):
                inputs = wd.get('inputs', {}) or {}
    except Exception:
        name = fname
        has_dispatch = False
        inputs = {}

    results.append({
        'file': fname,
        'name': name,
        'categories': wf_categories,
        'has_dispatch': has_dispatch,
        'dispatch_url': '/api/fsa/docs/dispatch',
        'inputs': list(inputs.keys()),
        'api_path': f'/api/fsa/docs/{stem}',
    })

print(json.dumps({'ok': True, 'count': len(results), 'items': results}, indent=2))
PYEOF
