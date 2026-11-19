#!/usr/bin/env bash
# Renders output from check-osp-ci.sh JSON results.
#
# Usage:
#   check-osp-ci-summary.sh <results.json>          # Markdown summary to stdout
#   check-osp-ci-summary.sh <results.json> --count  # failing repo count
#   check-osp-ci-summary.sh <results.json> --repos  # space-separated failing repo names

set -uo pipefail

results="${1:?results JSON file required}"
mode="${2:-summary}"

case "$mode" in
  --count)
    python3 -c "import json; print(len(json.load(open('${results}'))))"
    ;;
  --repos)
    python3 -c "
import json
data = json.load(open('${results}'))
print(' '.join(r['repo'] for r in data))
"
    ;;
  *)
    RESULTS_FILE="$results" python3 - << 'PYEOF'
import json, os, sys

results = os.environ["RESULTS_FILE"]
data = json.load(open(results))
count = len(data)

print("## OSP-Bound CI Status")
print("")

if count == 0:
    print("All OSP-bound repos are green on their default branch.")
else:
    print(f"**{count} repo(s) have CI failures on their default branch.**")
    print("")
    print("| Repo | Branch | Commit | Failing checks |")
    print("|---|---|---|---|")
    for r in data:
        repo      = r["full_repo"]
        branch    = r["branch"]
        sha_short = r["sha_short"]
        url       = r["url"]
        failures  = ", ".join(r["failures"]) if r["failures"] else "(status API failure)"
        print(f"| [{repo}](https://github.com/{repo}) | `{branch}` | [`{sha_short}`]({url}) | {failures} |")
PYEOF
    ;;
esac
