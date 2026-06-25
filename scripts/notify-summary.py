#!/usr/bin/env python3
"""
scripts/notify-summary.py — render notification breakdown for GITHUB_STEP_SUMMARY
Usage: notify-summary.py <notifs.json>
Reads the JSON file written by notify-manager.yml fetch step and prints
a markdown summary of notifications by type and top repos.
"""
import json, sys

notifs_file = sys.argv[1] if len(sys.argv) > 1 else '/tmp/notifs.json'

try:
    with open(notifs_file) as f:
        data = json.load(f)
except Exception as e:
    print(f'<!-- notify-summary: could not read {notifs_file}: {e} -->')
    sys.exit(0)

by_reason: dict[str, int] = {}
by_repo: dict[str, int] = {}

for n in data:
    r = n.get('reason', 'unknown')
    repo = n.get('repository', {}).get('full_name', 'unknown')
    by_reason[r] = by_reason.get(r, 0) + 1
    by_repo[repo] = by_repo.get(repo, 0) + 1

if by_reason:
    print('### By type')
    for reason, count in sorted(by_reason.items(), key=lambda x: -x[1]):
        print(f'- `{reason}`: {count}')
    print('')

if by_repo:
    print('### Top repos')
    for repo, count in sorted(by_repo.items(), key=lambda x: -x[1])[:10]:
        print(f'- `{repo}`: {count}')
