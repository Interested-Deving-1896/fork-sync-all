#!/usr/bin/env bash
# GET /api/fsa/docs/content
# Returns the rendered book/docs content index — pages, sections, and their
# GitHub Pages URLs. Reads from DOCS/ directory structure and book.toml.
#
# Query params:
#   ?format=index|toc|pages   (default: index)
#   ?section=<name>           (filter to a specific section)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

FORMAT="${QUERY_format:-index}"
SECTION="${QUERY_section:-}"

# Load per-instance identity — provides FSA_IDENTITY_DOCS_URL if reconcile
# has been run on this instance. Falls back to the source instance URL.
_IDENTITY_ENV="${_FSA_ROOT}/assets/brand/.active/identity.env"
FSA_IDENTITY_DOCS_URL="https://interested-deving-1896.github.io/fork-sync-all/"
if [[ -f "$_IDENTITY_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$_IDENTITY_ENV"
fi

python3 - << PYEOF
import os, json, re

repo_root = '${_FSA_ROOT}'
docs_dir = os.path.join(repo_root, 'DOCS')
book_toml = os.path.join(repo_root, 'book.toml')
format_req = '${FORMAT}'
section_filter = '${SECTION}'.lower()

# Parse book.toml for title and src dir
book_title = 'fork-sync-all Docs'
book_src = 'DOCS'
# Use per-instance docs URL from identity.env; fall back to source instance URL
pages_url = '${FSA_IDENTITY_DOCS_URL}' or 'https://interested-deving-1896.github.io/fork-sync-all/'

if os.path.exists(book_toml):
    content = open(book_toml).read()
    m = re.search(r'title\s*=\s*"([^"]+)"', content)
    if m: book_title = m.group(1)
    m = re.search(r'src\s*=\s*"([^"]+)"', content)
    if m: book_src = m.group(1)

# Walk DOCS/ and build page list
pages = []
if os.path.isdir(docs_dir):
    for root, dirs, files in os.walk(docs_dir):
        dirs.sort()
        for f in sorted(files):
            if not f.endswith('.md'):
                continue
            rel = os.path.relpath(os.path.join(root, f), docs_dir)
            section = rel.split(os.sep)[0] if os.sep in rel else ''
            if section_filter and section_filter not in section.lower() and section_filter not in f.lower():
                continue
            # Derive GitHub Pages URL
            url_path = rel.replace(os.sep, '/').replace('.md', '.html')
            if url_path == 'README.html':
                url_path = 'index.html'
            pages.append({
                'path': rel.replace(os.sep, '/'),
                'section': section,
                'title': f.replace('.md', '').replace('-', ' ').replace('_', ' ').title(),
                'url': pages_url + url_path,
            })

# Build sections index
sections = {}
for p in pages:
    s = p['section'] or 'root'
    sections.setdefault(s, []).append(p)

if format_req == 'toc':
    result = {'ok': True, 'title': book_title, 'pages_url': pages_url,
              'sections': {s: [p['title'] for p in ps] for s, ps in sections.items()}}
elif format_req == 'pages':
    result = {'ok': True, 'title': book_title, 'pages_url': pages_url,
              'count': len(pages), 'pages': pages}
else:  # index
    result = {
        'ok': True,
        'title': book_title,
        'pages_url': pages_url,
        'book_toml': os.path.exists(book_toml),
        'section_count': len(sections),
        'page_count': len(pages),
        'sections': list(sections.keys()),
        'dispatch_build': '/api/fsa/docs/dispatch',
        'engines': ['mdbook', 'mkdocs', 'pandoc'],
    }

print(json.dumps(result, indent=2))
PYEOF
