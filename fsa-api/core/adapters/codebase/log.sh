#!/usr/bin/env bash
# GET /api/fsa/codebase/log
# Returns recent commits to the FSA codebase (the FSA changelog).
#
# Query params:
#   ?limit=N          (default: 20, max: 100)
#   ?since=YYYY-MM-DD (only commits after this date)
#   ?author=<name>    (filter by author name substring)
#   ?path=<path>      (filter to commits touching a specific path)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

LIMIT="${QUERY_limit:-20}"
SINCE="${QUERY_since:-}"
AUTHOR="${QUERY_author:-}"
PATH_FILTER="${QUERY_path:-}"

cd "$_FSA_ROOT" || { fsa_error "cannot cd to FSA root" 500; exit 0; }

python3 - << PYEOF
import subprocess, json, sys

limit  = min(int('${LIMIT}') if '${LIMIT}'.isdigit() else 20, 100)
since  = '${SINCE}'
author = '${AUTHOR}'
path_f = '${PATH_FILTER}'

cmd = ['git', 'log', f'-{limit}',
       '--pretty=format:%H\x1f%h\x1f%s\x1f%an\x1f%ae\x1f%cI']

if since:
    cmd += [f'--since={since}']
if author:
    cmd += [f'--author={author}']
if path_f:
    cmd += ['--', path_f]

try:
    out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
except Exception as e:
    print(json.dumps({'ok': False, 'error': str(e)}))
    sys.exit(0)

commits = []
for line in out.splitlines():
    if not line.strip():
        continue
    parts = line.split('\x1f')
    if len(parts) < 6:
        continue
    sha, sha_short, msg, author_name, author_email, ts = parts[:6]
    commits.append({
        'sha':    sha,
        'short':  sha_short,
        'message': msg,
        'author': author_name,
        'email':  author_email,
        'timestamp': ts,
    })

print(json.dumps({'ok': True, 'count': len(commits), 'commits': commits}, indent=2))
PYEOF
