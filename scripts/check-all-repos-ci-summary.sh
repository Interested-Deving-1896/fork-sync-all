#!/usr/bin/env bash
# Renders output from check-all-repos-ci.sh JSON results.
#
# Usage:
#   check-all-repos-ci-summary.sh <results.json>          # Markdown summary to stdout
#   check-all-repos-ci-summary.sh <results.json> --count  # failing repo count
#   check-all-repos-ci-summary.sh <results.json> --repos  # space-separated failing repo names

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
import json, os

results = os.environ["RESULTS_FILE"]
data = json.load(open(results))
count = len(data)

print("## Broad CI Status — Interested-Deving-1896")
print("")

if count == 0:
    print("All repos with CI configured are passing.")
else:
    print(f"**{count} repo(s) have CI failures on their default branch.**")
    print("")
    print("| Repo | Branch | Commit | State | Failing checks |")
    print("|---|---|---|---|---|")
    for r in data:
        owner    = r.get("owner", "Interested-Deving-1896")
        repo     = r["repo"]
        branch   = r.get("branch", "")
        sha      = r.get("sha", "")
        state    = r.get("state", "")
        url      = r.get("url", "")
        contexts = r.get("contexts", [])
        state_icon = "❌" if state == "FAILURE" else "⚠️"
        ctx_str  = ", ".join(contexts[:5]) if contexts else "(rollup only)"
        if len(contexts) > 5:
            ctx_str += f" +{len(contexts)-5} more"
        print(f"| [{owner}/{repo}](https://github.com/{owner}/{repo}) | `{branch}` | [`{sha}`]({url}) | {state_icon} {state} | {ctx_str} |")
PYEOF
    ;;
esac
