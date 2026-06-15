#!/usr/bin/env bash
# Renders output from check-osp-pr-ci.sh JSON results.
#
# Usage:
#   check-osp-pr-ci-summary.sh <results.json>          # Markdown summary to stdout
#   check-osp-pr-ci-summary.sh <results.json> --count  # failing PR count
#   check-osp-pr-ci-summary.sh <results.json> --repos  # space-separated repo names with failing PRs

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
repos = sorted(set(r['repo'] for r in data))
print(' '.join(repos))
"
    ;;
  *)
    RESULTS_FILE="$results" python3 - << 'PYEOF'
import json, os

results = os.environ["RESULTS_FILE"]
data = json.load(open(results))
count = len(data)

print("## OSP-Bound PR CI Status")
print("")

if count == 0:
    print("All open PRs on OSP-bound repos have passing CI (or no CI configured).")
else:
    print(f"**{count} open PR(s) have failing CI.**")
    print("")
    print("| Repo | PR | Author | Branch | Commit | State | Failing checks |")
    print("|---|---|---|---|---|---|---|")
    for r in data:
        owner    = r.get("owner", "Interested-Deving-1896")
        repo     = r["repo"]
        pr_num   = r["pr"]
        title    = r.get("title", "")[:60]
        author   = r.get("author", "")
        branch   = r.get("branch", "")
        sha      = r.get("sha", "")
        state    = r.get("state", "")
        url      = r.get("url", "")
        contexts = r.get("contexts", [])
        state_icon = "❌" if state == "FAILURE" else "⚠️"
        ctx_str  = ", ".join(contexts[:4]) if contexts else "(rollup only)"
        if len(contexts) > 4:
            ctx_str += f" +{len(contexts)-4} more"
        print(f"| [{owner}/{repo}](https://github.com/{owner}/{repo}) | [#{pr_num}]({url}) \"{title}\" | @{author} | `{branch}` | `{sha}` | {state_icon} {state} | {ctx_str} |")
PYEOF
    ;;
esac
