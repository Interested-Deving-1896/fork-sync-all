#!/usr/bin/env bash
#
# PR automation — native GitHub Actions equivalent of gitStream (linear-b/gitstream).
#
# Runs on pull_request and pull_request_review events. Performs:
#
#   1. Auto-label     — applies labels based on changed file paths and PR metadata
#   2. Auto-assign    — assigns reviewers based on changed paths and team config
#   3. Flag problems  — posts a review comment when risky patterns are detected
#   4. Auto-merge     — enables auto-merge for low-risk PRs (docs, deps, tests)
#   5. Size label     — adds xs/s/m/l/xl label based on lines changed
#
# Required env vars:
#   GH_TOKEN    — PAT with repo + pull_requests + read:org scopes
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   PR_NUMBER   — pull request number
#
# Optional env vars:
#   REVIEWERS_MAP   — JSON: path_pattern → reviewer_login(s)
#                     e.g. '{"scripts/":["alice"],"workflows/":["bob","alice"]}'
#   TEAM_REVIEWERS  — JSON: path_pattern → team_slug(s)
#                     e.g. '{"src/":["backend-team"]}'
#   AUTO_MERGE_PATTERNS — JSON array of path regexes that qualify for auto-merge
#                         e.g. '["^docs/","^README","^\\.github/workflows/update-"]'
#   LABEL_MAP       — JSON: path_pattern → label_name
#                     e.g. '{"scripts/":"scripts","docs/":"documentation"}'
#   FLAG_PATTERNS   — JSON array of risky file patterns to flag
#                     e.g. '["secrets","password","token","private_key"]'
#   SIZE_THRESHOLDS — JSON: {"xs":10,"s":50,"m":200,"l":500} (lines changed)
#   DRY_RUN         — true | false

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required (owner/repo)}"
: "${PR_NUMBER:?PR_NUMBER is required}"

REVIEWERS_MAP="${REVIEWERS_MAP:-{}}"
TEAM_REVIEWERS="${TEAM_REVIEWERS:-{}}"
AUTO_MERGE_PATTERNS="${AUTO_MERGE_PATTERNS:-[\"^docs/\",\"^README\",\"^CHANGELOG\",\"\\\\.md$\",\"^scripts/update-\",\"^\\.github/workflows/update-\"]}"
LABEL_MAP="${LABEL_MAP:-{\"scripts/\":\"scripts\",\".github/workflows/\":\"ci\",\"docs/\":\"documentation\",\"README\":\"documentation\",\".md$\":\"documentation\"}}"
FLAG_PATTERNS="${FLAG_PATTERNS:-[\"password\",\"secret\",\"private_key\",\"BEGIN RSA\",\"BEGIN EC\",\"token.*=.*['\\\"][a-zA-Z0-9]{20,}\"]}"
SIZE_THRESHOLDS="${SIZE_THRESHOLDS:-{\"xs\":10,\"s\":50,\"m\":200,\"l\":500}}"
DRY_RUN="${DRY_RUN:-false}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

info()  { echo "[pr-automation] $*"; }
warn()  { echo "[pr-automation][warn] $*" >&2; }
dry()   { echo "[pr-automation][dry-run] $*"; }

api_get() {
  curl --disable --silent "${AUTH[@]}" "$@"
}

api_post() {
  local url="$1" data="$2"
  curl --disable --silent -X POST "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    --data "$data" "$url"
}

api_patch() {
  local url="$1" data="$2"
  curl --disable --silent -X PATCH "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    --data "$data" "$url"
}

# ── Fetch PR metadata ─────────────────────────────────────────────────────────

info "Fetching PR #${PR_NUMBER} from ${REPO} ..."

pr_data=$(api_get "${API}/repos/${REPO}/pulls/${PR_NUMBER}")
pr_title=$(echo "$pr_data"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))")
pr_author=$(echo "$pr_data"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('user',{}).get('login',''))")
pr_base=$(echo "$pr_data"     | python3 -c "import json,sys; print(json.load(sys.stdin).get('base',{}).get('ref',''))")
pr_draft=$(echo "$pr_data"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('draft',False))")
pr_node_id=$(echo "$pr_data"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('node_id',''))")
pr_additions=$(echo "$pr_data"| python3 -c "import json,sys; print(json.load(sys.stdin).get('additions',0))")
pr_deletions=$(echo "$pr_data"| python3 -c "import json,sys; print(json.load(sys.stdin).get('deletions',0))")

info "  Title:   ${pr_title}"
info "  Author:  ${pr_author}"
info "  Base:    ${pr_base}"
info "  Draft:   ${pr_draft}"
info "  +${pr_additions} / -${pr_deletions}"
echo ""

# ── Fetch changed files ───────────────────────────────────────────────────────

changed_files=()
page=1
while true; do
  result=$(api_get "${API}/repos/${REPO}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}")
  count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  [[ "$count" -eq 0 ]] && break
  while IFS= read -r f; do
    changed_files+=("$f")
  done < <(echo "$result" | python3 -c "import json,sys; [print(f['filename']) for f in json.load(sys.stdin)]")
  (( page++ ))
done

info "Changed files (${#changed_files[@]}):"
for f in "${changed_files[@]}"; do
  info "  ${f}"
done
echo ""

# ── 1. Size label ─────────────────────────────────────────────────────────────

total_lines=$(( pr_additions + pr_deletions ))
size_label=$(python3 -c "
import json
thresholds = json.loads('${SIZE_THRESHOLDS}')
total = ${total_lines}
if   total <= thresholds.get('xs', 10):  print('size/xs')
elif total <= thresholds.get('s',  50):  print('size/s')
elif total <= thresholds.get('m', 200):  print('size/m')
elif total <= thresholds.get('l', 500):  print('size/l')
else:                                    print('size/xl')
")

info "Size label: ${size_label} (${total_lines} lines changed)"

# Ensure size labels exist
for lbl in size/xs size/s size/m size/l size/xl; do
  api_post "${API}/repos/${REPO}/labels" \
    "{\"name\":\"${lbl}\",\"color\":\"0075ca\"}" > /dev/null 2>&1 || true
done

# Remove existing size labels then add new one
existing_labels=$(api_get "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
  | python3 -c "import json,sys; [print(l['name']) for l in json.load(sys.stdin)]" 2>/dev/null || true)

while IFS= read -r lbl; do
  [[ "$lbl" == size/* ]] || continue
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would remove label ${lbl}"
  else
    curl --disable --silent -X DELETE "${AUTH[@]}" \
      "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels/$(python3 -c "import urllib.parse; print(urllib.parse.quote('${lbl}'))")" > /dev/null || true
  fi
done <<< "$existing_labels"

if [[ "$DRY_RUN" == "true" ]]; then
  dry "would add label ${size_label}"
else
  api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
    "{\"labels\":[\"${size_label}\"]}" > /dev/null
  info "  Applied ${size_label}"
fi

# ── 2. Path-based labels ──────────────────────────────────────────────────────

info "Applying path-based labels ..."

labels_to_add=$(python3 -c "
import json, re
label_map = json.loads('${LABEL_MAP}')
files = $(python3 -c "import json; print(json.dumps(${changed_files[*]+\"${changed_files[@]}\"}))" 2>/dev/null || echo '[]')
matched = set()
for pattern, label in label_map.items():
    for f in files:
        if re.search(pattern, f):
            matched.add(label)
            break
for l in sorted(matched):
    print(l)
" 2>/dev/null || true)

# Ensure labels exist and apply them
while IFS= read -r lbl; do
  [[ -z "$lbl" ]] && continue
  api_post "${API}/repos/${REPO}/labels" \
    "{\"name\":\"${lbl}\",\"color\":\"e4e669\"}" > /dev/null 2>&1 || true
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would add label ${lbl}"
  else
    api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
      "{\"labels\":[\"${lbl}\"]}" > /dev/null
    info "  Applied label: ${lbl}"
  fi
done <<< "$labels_to_add"

# ── 3. Auto-assign reviewers ──────────────────────────────────────────────────

info "Checking reviewer assignments ..."

reviewers_to_add=$(python3 -c "
import json, re
reviewers_map = json.loads('${REVIEWERS_MAP}')
author = '${pr_author}'
files = $(python3 -c "
import json, sys
files = []
" 2>/dev/null || echo "[]")
matched = set()
for pattern, logins in reviewers_map.items():
    for f in ${changed_files[@]+"${changed_files[@]}"} ; do
        :
    done
for pattern, logins in reviewers_map.items():
    matched.update(logins)
# Remove PR author from reviewers
matched.discard(author)
for r in sorted(matched):
    print(r)
" 2>/dev/null || true)

# Simpler approach: use bash to match patterns
declare -A reviewer_set
python3 - <<PYEOF
import json, re, sys

reviewers_map = json.loads(r"""${REVIEWERS_MAP}""")
author = "${pr_author}"
changed = ${changed_files[@]+"$(printf '"%s"\n' "${changed_files[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))")"}

matched = set()
for pattern, logins in reviewers_map.items():
    for f in changed:
        if re.search(pattern, f):
            if isinstance(logins, list):
                matched.update(logins)
            else:
                matched.add(logins)
            break

matched.discard(author)
for r in sorted(matched):
    print(r)
PYEOF

reviewers_json=$(python3 - <<PYEOF
import json, re

reviewers_map = json.loads(r"""${REVIEWERS_MAP}""")
author = "${pr_author}"
changed = $(python3 -c "
import json
files = $(printf '%s\n' "${changed_files[@]+"${changed_files[@]}"}" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]')
print(json.dumps(files))
" 2>/dev/null || echo '[]')

matched = set()
for pattern, logins in reviewers_map.items():
    for f in changed:
        if re.search(pattern, f):
            if isinstance(logins, list):
                matched.update(logins)
            else:
                matched.add(logins)
            break

matched.discard(author)
print(json.dumps(sorted(matched)))
PYEOF
)

team_reviewers_json=$(python3 - <<PYEOF
import json, re

team_map = json.loads(r"""${TEAM_REVIEWERS}""")
changed = $(python3 -c "
import json
files = $(printf '%s\n' "${changed_files[@]+"${changed_files[@]}"}" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]')
print(json.dumps(files))
" 2>/dev/null || echo '[]')

matched = set()
for pattern, teams in team_map.items():
    for f in changed:
        if re.search(pattern, f):
            if isinstance(teams, list):
                matched.update(teams)
            else:
                matched.add(teams)
            break

print(json.dumps(sorted(matched)))
PYEOF
)

reviewer_count=$(echo "$reviewers_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
team_count=$(echo "$team_reviewers_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [[ "$reviewer_count" -gt 0 || "$team_count" -gt 0 ]]; then
  payload=$(python3 -c "
import json
r = json.loads('${reviewers_json}')
t = json.loads('${team_reviewers_json}')
print(json.dumps({'reviewers': r, 'team_reviewers': t}))
")
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would request reviewers: ${reviewers_json} teams: ${team_reviewers_json}"
  else
    result=$(api_post "${API}/repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" "$payload")
    info "  Requested reviewers: ${reviewers_json}"
    info "  Requested teams:     ${team_reviewers_json}"
  fi
else
  info "  No reviewer rules matched."
fi

# ── 4. Flag problems ──────────────────────────────────────────────────────────

info "Scanning diff for risky patterns ..."

# Fetch the diff — write to a temp file to avoid shell interpolation issues
# with backticks, $-signs, and triple-quote sequences inside Python heredocs.
diff_file=$(mktemp)
trap 'rm -f "$diff_file"' EXIT
api_get \
  -H "Accept: application/vnd.github.v3.diff" \
  "${API}/repos/${REPO}/pulls/${PR_NUMBER}" > "$diff_file" 2>/dev/null || true

flagged=$(FLAG_PATTERNS="$FLAG_PATTERNS" python3 - "$diff_file" << 'PYEOF'
import re, sys, os, json

patterns = json.loads(os.environ.get('FLAG_PATTERNS', '[]'))
diff_path = sys.argv[1] if len(sys.argv) > 1 else ''

try:
    diff = open(diff_path).read() if diff_path else ''
except OSError:
    diff = ''

findings = []
for i, line in enumerate(diff.splitlines(), 1):
    if not line.startswith('+'):
        continue
    for pattern in patterns:
        try:
            if re.search(pattern, line, re.IGNORECASE):
                findings.append(f"Line {i}: {line[:120]}")
                break
        except re.error:
            pass

for f in findings[:20]:
    print(f)
PYEOF
)

if [[ -n "$flagged" ]]; then
  warn "Risky patterns detected in diff:"
  echo "$flagged" | while IFS= read -r line; do
    warn "  ${line}"
  done

  comment_body=$(FLAGGED="$flagged" python3 - << 'PYEOF'
import json, os
findings = os.environ.get('FLAGGED', '')
body = (
    '## ⚠️ Automated review: risky patterns detected\n\n'
    'The following lines matched risk patterns and should be reviewed before merging:\n\n'
    '```\n' + findings + '\n```\n\n'
    '_This comment was generated automatically by pr-automation.sh._'
)
print(json.dumps({'body': body}))
PYEOF
)

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would post risk comment"
  else
    api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/comments" "$comment_body" > /dev/null
    info "  Posted risk comment."
  fi

  # Add a 'needs-review' label
  api_post "${API}/repos/${REPO}/labels" \
    '{"name":"needs-review","color":"d93f0b"}' > /dev/null 2>&1 || true
  if [[ "$DRY_RUN" != "true" ]]; then
    api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
      '{"labels":["needs-review"]}' > /dev/null
  fi
else
  info "  No risky patterns found."
fi

# ── 5. Auto-merge ─────────────────────────────────────────────────────────────

info "Evaluating auto-merge eligibility ..."

# Not eligible if: draft, targets non-default branch, or has risky patterns
if [[ "$pr_draft" == "True" ]]; then
  info "  Draft PR — skipping auto-merge."
elif [[ -n "$flagged" ]]; then
  info "  Risky patterns detected — skipping auto-merge."
else
  # Check if all changed files match auto-merge patterns
  all_match=$(python3 - <<PYEOF
import re, json

patterns = json.loads(r"""${AUTO_MERGE_PATTERNS}""")
files = $(python3 -c "
import json
files = $(printf '%s\n' "${changed_files[@]+"${changed_files[@]}"}" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]')
print(json.dumps(files))
" 2>/dev/null || echo '[]')

if not files:
    print('false')
else:
    for f in files:
        if not any(re.search(p, f) for p in patterns):
            print('false')
            exit()
    print('true')
PYEOF
)

  if [[ "$all_match" == "true" ]]; then
    info "  All changed files match auto-merge patterns — enabling auto-merge ..."

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would enable auto-merge (squash) on PR #${PR_NUMBER}"
    else
      # Enable auto-merge via GraphQL (REST API doesn't support it).
      # Requires the repo to have branch protection with at least one required
      # status check — if not configured, GitHub returns an error; we warn
      # and continue rather than failing the job.
      query=$(PR_NODE_ID="$pr_node_id" python3 - << 'PYEOF'
import json, os
node_id = os.environ['PR_NODE_ID']
q = f'mutation {{ enablePullRequestAutoMerge(input: {{pullRequestId: "{node_id}", mergeMethod: SQUASH}}) {{ pullRequest {{ autoMergeRequest {{ mergeMethod }} }} }} }}'
print(json.dumps({'query': q}))
PYEOF
)
      result=$(curl --disable --silent -X POST \
        "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        --data "$query" \
        "https://api.github.com/graphql" || echo '{}')
      merge_method=$(echo "$result" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('enablePullRequestAutoMerge',{}).get('pullRequest',{}).get('autoMergeRequest',{}).get('mergeMethod',''))" \
        2>/dev/null || true)
      gql_errors=$(echo "$result" | python3 -c \
        "import json,sys; errs=json.load(sys.stdin).get('errors',[]); print(errs[0].get('message','') if errs else '')" \
        2>/dev/null || true)
      if [[ -n "$merge_method" ]]; then
        info "  Auto-merge enabled: ${merge_method}"
      else
        warn "  Auto-merge not enabled: ${gql_errors:-unknown error (branch protection may not be configured)}"
      fi

      # Add auto-merge label
      api_post "${API}/repos/${REPO}/labels" \
        '{"name":"auto-merge","color":"0e8a16"}' > /dev/null 2>&1 || true
      api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
        '{"labels":["auto-merge"]}' > /dev/null
    fi
  else
    info "  Not all files match auto-merge patterns — manual review required."
  fi
fi

echo ""
info "PR automation complete for #${PR_NUMBER}."
