#!/usr/bin/env bash
# GET /api/fsa/docs/status
# Returns the last run status for all docs/publishing workflows in one call.
#
# Query params:
#   ?category=all|book|readme|translate|sbom|notebooklm  (default: all)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

CATEGORY="${QUERY_category:-all}"

fsa_quota_check 80 || exit 0

# Fetch last run for each docs workflow via GraphQL (1 API call)
DOCS_WORKFLOWS="book-export.yml deploy-book.yml generate-book-pages.yml update-book-index.yml
sync-eggs-docs-to-book.yml gitbook-oss.yml create-readmes.yml update-readmes.yml
lts-readmes.yml readme-wizard.yml validate-readme-render.yml translate-readmes.yml
translate-docs.yml generate-sbom.yml generate-notebooklm.yml refresh-notebooklm-auth.yml
upload-notebooklm.yml generate-dep-graph.yml generate-repo-descriptions.yml
update-workflow-triggers-doc.yml trigger-readme-update.yml"

python3 - << PYEOF
import json, os, subprocess, sys

repo_root = '${_FSA_ROOT}'
fsa_repo = '${FSA_REPO}'
gh_token = '${GH_TOKEN}'
category = '${CATEGORY}'

CATEGORIES = {
    'book':       ['book-export', 'deploy-book', 'generate-book-pages', 'update-book-index',
                   'sync-eggs-docs-to-book', 'gitbook-oss'],
    'readme':     ['create-readmes', 'update-readmes', 'lts-readmes', 'readme-wizard',
                   'validate-readme-render', 'translate-readmes', 'trigger-readme-update'],
    'translate':  ['translate-docs', 'translate-readmes'],
    'sbom':       ['generate-sbom'],
    'notebooklm': ['generate-notebooklm', 'refresh-notebooklm-auth', 'upload-notebooklm'],
    'generate':   ['generate-book-pages', 'generate-dep-graph', 'generate-repo-descriptions',
                   'generate-notebooklm', 'generate-sbom', 'update-workflow-triggers-doc'],
}

ALL_DOC_STEMS = set()
for stems in CATEGORIES.values():
    ALL_DOC_STEMS.update(stems)

import urllib.request, urllib.error

def gh_get(path):
    url = f'https://api.github.com{path}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'token {gh_token}',
        'Accept': 'application/vnd.github+json',
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception:
        return {}

results = []
for stem in sorted(ALL_DOC_STEMS):
    if category != 'all':
        if stem not in CATEGORIES.get(category, []):
            continue

    for ext in ['.yml', '.yaml']:
        wf_file = stem + ext
        wf_path = os.path.join(repo_root, '.github/workflows', wf_file)
        if os.path.exists(wf_path):
            break
    else:
        continue

    runs = gh_get(f'/repos/{fsa_repo}/actions/workflows/{wf_file}/runs?per_page=1')
    last = (runs.get('workflow_runs') or [{}])[0]
    results.append({
        'workflow': wf_file,
        'categories': [c for c, stems in CATEGORIES.items() if stem in stems],
        'status': last.get('status', 'unknown'),
        'conclusion': last.get('conclusion'),
        'run_url': last.get('html_url', ''),
        'created_at': last.get('created_at', ''),
        'dispatch_url': '/api/fsa/docs/dispatch',
    })

print(json.dumps({'ok': True, 'count': len(results), 'items': results}, indent=2))
PYEOF
