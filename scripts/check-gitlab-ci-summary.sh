#!/usr/bin/env bash
# Renders output from check-gitlab-ci.sh JSON results.
#
# Usage:
#   check-gitlab-ci-summary.sh <results.json>          # Markdown summary to stdout
#   check-gitlab-ci-summary.sh <results.json> --count  # failing repo count
#   check-gitlab-ci-summary.sh <results.json> --repos  # space-separated failing repo names

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

print("## GitLab CI Pipeline Status")
print("")

if count == 0:
    print("All OSP-bound GitLab mirrors have passing pipelines.")
else:
    print(f"**{count} repo(s) have failing pipelines on GitLab.**")
    print("")
    print("| Repo | Branch | Commit | Status | Pipeline |")
    print("|---|---|---|---|---|")
    for r in data:
        gl_path  = r["gl_path"]
        ref      = r.get("ref", "")
        sha      = r.get("sha", "")
        status   = r["status"]
        web_url  = r.get("web_url", "")
        pid      = r.get("pipeline_id", "")
        gl_url   = f"https://gitlab.com/{gl_path}"
        status_icon = {"failed": "❌", "canceled": "⚠️", "blocked": "🔒"}.get(status, "❓")
        pipeline_link = f"[#{pid}]({web_url})" if web_url else str(pid)
        print(f"| [{gl_path}]({gl_url}) | `{ref}` | `{sha}` | {status_icon} {status} | {pipeline_link} |")
PYEOF
    ;;
esac
