#!/usr/bin/env python3
"""
scripts/notify-triage-ids.py — print notification IDs matching known-safe patterns
Usage: notify-triage-ids.py <notifs.json>
Prints one notification thread ID per line for notifications whose subject
title matches a known-safe auto-triage pattern.
"""
import json, sys

PATTERNS = [
    'Mirror to OpenOS-Project-OSP',
    'Sync btrfs-devel Branches',
    'Rate limit',
    'rate limit',
    'Quota',
    'quota exhausted',
    'Dependabot',
    'chore(deps)',
    'chore: bump',
    'build(deps)',
]

notifs_file = sys.argv[1] if len(sys.argv) > 1 else '/tmp/notifs.json'

try:
    with open(notifs_file) as f:
        data = json.load(f)
except Exception as e:
    print(f'error reading {notifs_file}: {e}', file=sys.stderr)
    sys.exit(0)

for n in data:
    title = n.get('subject', {}).get('title', '')
    if any(p in title for p in PATTERNS):
        print(n['id'])
