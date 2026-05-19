#!/usr/bin/env bash
#
# PR automation — native GitHub Actions equivalent of gitStream (linear-b/gitstream).
#
# Runs on pull_request and pull_request_review events. Performs:
#
#   1. Size label     — xs/s/m/l/xl based on lines changed
#   2. Path labels    — labels based on changed file paths
#   3. Auto-assign    — reviewer assignment based on changed paths
#   4. Flag problems  — review comment when risky patterns are detected
#   5. Auto-merge     — enables auto-merge for low-risk PRs
#
# Required env vars:
#   GH_TOKEN    — github.token (always available on PR events; needs
#                 pull-requests:write and contents:read)
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   PR_NUMBER   — pull request number
#
# Optional env vars:
#   SYNC_TOKEN          — PAT used only for GraphQL enablePullRequestAutoMerge;
#                         falls back to GH_TOKEN when absent
#   REVIEWERS_MAP       — JSON: {"path_pattern": ["login", ...], ...}
#   TEAM_REVIEWERS      — JSON: {"path_pattern": ["team-slug", ...], ...}
#   AUTO_MERGE_PATTERNS — JSON array of path regexes that qualify for auto-merge
#   LABEL_MAP           — JSON: {"path_pattern": "label-name", ...}
#   FLAG_PATTERNS       — JSON array of line-content regexes to flag as risky
#   SIZE_THRESHOLDS     — JSON: {"xs":10,"s":50,"m":200,"l":500}
#   DRY_RUN             — true | false

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required (owner/repo)}"
: "${PR_NUMBER:?PR_NUMBER is required}"

SYNC_TOKEN="${SYNC_TOKEN:-}"
REVIEWERS_MAP="${REVIEWERS_MAP:-{}}"
TEAM_REVIEWERS="${TEAM_REVIEWERS:-{}}"
AUTO_MERGE_PATTERNS="${AUTO_MERGE_PATTERNS:-[\"^docs/\",\"^README\",\"^CHANGELOG\",\"\\\\.md$\",\"^scripts/update-\",\"^\\.github/workflows/update-\",\"^\\.github/workflows/rotate-\"]}"
LABEL_MAP="${LABEL_MAP:-{\".github/workflows/\":\"ci\",\"scripts/\":\"scripts\",\"docs/\":\"documentation\",\"README\":\"documentation\",\"\\.md$\":\"documentation\",\"registered-imports\":\"imports\"}}"
FLAG_PATTERNS="${FLAG_PATTERNS:-[\"password\\\\s*=\",\"secret\\\\s*=\",\"private_key\",\"BEGIN RSA PRIVATE\",\"BEGIN EC PRIVATE\",\"ghp_[a-zA-Z0-9]{36}\",\"glpat-[a-zA-Z0-9_-]{20}\"]}"
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

# ── Fetch PR metadata ─────────────────────────────────────────────────────────

info "Fetching PR #${PR_NUMBER} from ${REPO} ..."

pr_data=$(api_get "${API}/repos/${REPO}/pulls/${PR_NUMBER}")
pr_meta_file=$(mktemp)
trap 'rm -f "$pr_meta_file"' EXIT
echo "$pr_data" > "$pr_meta_file"

# Extract each field on its own line — avoids read -r word-splitting on
# PR titles that contain spaces.
pr_title=$(     python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('title',''))"                       "$pr_meta_file")
pr_author=$(    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user',{}).get('login',''))"         "$pr_meta_file")
pr_base=$(      python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('base',{}).get('ref',''))"           "$pr_meta_file")
pr_draft=$(     python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('draft',False))"                    "$pr_meta_file")
pr_node_id=$(   python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('node_id',''))"                     "$pr_meta_file")
pr_additions=$( python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('additions',0))"                    "$pr_meta_file")
pr_deletions=$( python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('deletions',0))"                    "$pr_meta_file")

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

# Serialise changed files to JSON once — all Python blocks read this env var
changed_files_json="[]"
if [[ "${#changed_files[@]}" -gt 0 ]]; then
  changed_files_json=$(printf '%s\n' "${changed_files[@]}" \
    | python3 -c "import json,sys; print(json.dumps([l.rstrip('\n') for l in sys.stdin]))")
fi

info "Changed files (${#changed_files[@]}):"
for f in "${changed_files[@]+"${changed_files[@]}"}"; do
  info "  ${f}"
done
echo ""

# ── 1. Size label ─────────────────────────────────────────────────────────────

total_lines=$(( pr_additions + pr_deletions ))
size_label=$(SIZE_THRESHOLDS="$SIZE_THRESHOLDS" TOTAL_LINES="$total_lines" \
  python3 - << 'PYEOF'
import json, os
thresholds = json.loads(os.environ['SIZE_THRESHOLDS'])
total      = int(os.environ['TOTAL_LINES'])
if   total <= thresholds.get('xs', 10):  print('size/xs')
elif total <= thresholds.get('s',  50):  print('size/s')
elif total <= thresholds.get('m', 200):  print('size/m')
elif total <= thresholds.get('l', 500):  print('size/l')
else:                                    print('size/xl')
PYEOF
)

info "Size label: ${size_label} (${total_lines} lines changed)"

for lbl in size/xs size/s size/m size/l size/xl; do
  api_post "${API}/repos/${REPO}/labels" \
    "{\"name\":\"${lbl}\",\"color\":\"0075ca\"}" > /dev/null 2>&1 || true
done

existing_labels=$(api_get "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels" \
  | python3 -c "import json,sys; [print(l['name']) for l in json.load(sys.stdin)]" 2>/dev/null || true)

while IFS= read -r lbl; do
  [[ "$lbl" == size/* ]] || continue
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would remove label ${lbl}"
  else
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$lbl")
    curl --disable --silent -X DELETE "${AUTH[@]}" \
      "${API}/repos/${REPO}/issues/${PR_NUMBER}/labels/${encoded}" > /dev/null || true
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

labels_to_add=$(LABEL_MAP="$LABEL_MAP" CHANGED_FILES="$changed_files_json" \
  python3 - << 'PYEOF'
import json, re, os
label_map = json.loads(os.environ['LABEL_MAP'])
files     = json.loads(os.environ['CHANGED_FILES'])
matched   = set()
for pattern, label in label_map.items():
    for f in files:
        if re.search(pattern, f):
            matched.add(label)
            break
for l in sorted(matched):
    print(l)
PYEOF
)

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

reviewers_json=$(REVIEWERS_MAP="$REVIEWERS_MAP" CHANGED_FILES="$changed_files_json" PR_AUTHOR="$pr_author" \
  python3 - << 'PYEOF'
import json, re, os
reviewers_map = json.loads(os.environ['REVIEWERS_MAP'])
files         = json.loads(os.environ['CHANGED_FILES'])
author        = os.environ['PR_AUTHOR']
matched = set()
for pattern, logins in reviewers_map.items():
    for f in files:
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

team_reviewers_json=$(TEAM_REVIEWERS="$TEAM_REVIEWERS" CHANGED_FILES="$changed_files_json" \
  python3 - << 'PYEOF'
import json, re, os
team_map = json.loads(os.environ['TEAM_REVIEWERS'])
files    = json.loads(os.environ['CHANGED_FILES'])
matched  = set()
for pattern, teams in team_map.items():
    for f in files:
        if re.search(pattern, f):
            if isinstance(teams, list):
                matched.update(teams)
            else:
                matched.add(teams)
            break
print(json.dumps(sorted(matched)))
PYEOF
)

reviewer_count=$(echo "$reviewers_json"  | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
team_count=$(echo "$team_reviewers_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [[ "$reviewer_count" -gt 0 || "$team_count" -gt 0 ]]; then
  payload=$(REVIEWERS="$reviewers_json" TEAMS="$team_reviewers_json" \
    python3 - << 'PYEOF'
import json, os
print(json.dumps({
    'reviewers':      json.loads(os.environ['REVIEWERS']),
    'team_reviewers': json.loads(os.environ['TEAMS']),
}))
PYEOF
)
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would request reviewers: ${reviewers_json} teams: ${team_reviewers_json}"
  else
    api_post "${API}/repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" "$payload" > /dev/null
    info "  Requested reviewers: ${reviewers_json}"
    info "  Requested teams:     ${team_reviewers_json}"
  fi
else
  info "  No reviewer rules matched."
fi

# ── 4. Flag problems ──────────────────────────────────────────────────────────

info "Scanning diff for risky patterns ..."

diff_file=$(mktemp)
api_get \
  -H "Accept: application/vnd.github.v3.diff" \
  "${API}/repos/${REPO}/pulls/${PR_NUMBER}" > "$diff_file" 2>/dev/null || true

flagged=$(FLAG_PATTERNS="$FLAG_PATTERNS" python3 - "$diff_file" << 'PYEOF'
import re, sys, os, json

patterns  = json.loads(os.environ.get('FLAG_PATTERNS', '[]'))
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
rm -f "$diff_file"

if [[ -n "$flagged" ]]; then
  warn "Risky patterns detected:"
  while IFS= read -r line; do warn "  ${line}"; done <<< "$flagged"

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
    dry "would post review comment"
  else
    api_post "${API}/repos/${REPO}/issues/${PR_NUMBER}/comments" "$comment_body" > /dev/null
    info "  Posted review comment."
  fi
else
  info "  No risky patterns found."
fi

# ── 5. Auto-merge ─────────────────────────────────────────────────────────────

info "Evaluating auto-merge eligibility ..."

if [[ "$pr_draft" == "True" ]]; then
  info "  Draft PR — skipping auto-merge."
elif [[ -n "$flagged" ]]; then
  info "  Risky patterns detected — skipping auto-merge."
else
  all_match=$(AUTO_MERGE_PATTERNS="$AUTO_MERGE_PATTERNS" CHANGED_FILES="$changed_files_json" \
    python3 - << 'PYEOF'
import re, json, os
patterns = json.loads(os.environ['AUTO_MERGE_PATTERNS'])
files    = json.loads(os.environ['CHANGED_FILES'])
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
      automerge_token="${SYNC_TOKEN:-${GH_TOKEN}}"
      query=$(PR_NODE_ID="$pr_node_id" python3 - << 'PYEOF'
import json, os
node_id = os.environ['PR_NODE_ID']
q = (
    'mutation { enablePullRequestAutoMerge('
    f'input: {{pullRequestId: "{node_id}", mergeMethod: SQUASH}}'
    ') { pullRequest { autoMergeRequest { mergeMethod } } } }'
)
print(json.dumps({'query': q}))
PYEOF
)
      result=$(curl --disable --silent -X POST \
        -H "Authorization: token ${automerge_token}" \
        -H "Accept: application/vnd.github+json" \
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
    fi
  else
    info "  Not all files match auto-merge patterns — skipping."
  fi
fi

info "PR automation complete."
