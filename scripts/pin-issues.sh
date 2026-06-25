#!/usr/bin/env bash
# scripts/pin-issues.sh — GitHub repository issue pin management
#
# Reads config/fsa-pin.yml issues block. For each configured repo:
#   - Pins explicitly listed issues (GraphQL: pinIssue mutation)
#   - Unpins resolved issues when unpin_resolved: true
#   - Auto-pins the most-reacted open issue when no explicit pin is set
#     and auto_pin_top_issue: true globally
#
# Requires a token with `repo` scope.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/includes/gh-api.sh"

info() { echo "[pin-issues] $*" >&2; }
warn() { echo "[pin-issues][warn] $*" >&2; }
dry()  { echo "[pin-issues][dry-run] $*" >&2; }

PIN_CFG="$REPO_ROOT/config/fsa-pin.yml"
DRY_RUN="${DRY_RUN:-false}"

[[ -f "$PIN_CFG" ]] || { warn "config/fsa-pin.yml not found"; exit 0; }

enabled=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('issues',{}).get('enabled', False)).lower())
" 2>/dev/null)

[[ "$enabled" == "true" ]] || { info "issue pinning disabled — skipping"; exit 0; }

auto_pin_top=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('issues',{}).get('auto_pin_top_issue', True)).lower())
" 2>/dev/null)

# ── GraphQL helpers ───────────────────────────────────────────────────────────
gql() {
  local query="$1"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/graphql" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$query")" \
    2>/dev/null || echo '{}'
}

gql_vars() {
  local query="$1" vars="$2"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/graphql" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1], 'variables': json.loads(sys.argv[2])}))" "$query" "$vars")" \
    2>/dev/null || echo '{}'
}

# ── Process each repo ─────────────────────────────────────────────────────────
while IFS= read -r repo_json; do
  repo_full=$(echo "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('repo',''))" 2>/dev/null)
  unpin_resolved=$(echo "$repo_json" | python3 -c "import json,sys; print(str(json.load(sys.stdin).get('unpin_resolved',True)).lower())" 2>/dev/null)
  issue_number=$(echo "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('issue_number',''))" 2>/dev/null)

  [[ -z "$repo_full" ]] && continue
  owner="${repo_full%%/*}"
  repo="${repo_full##*/}"

  info "processing ${repo_full}"

  # ── Fetch current pinned issues + their state ─────────────────────────────
  pinned_data=$(gql "
{
  repository(owner: \"${owner}\", name: \"${repo}\") {
    id
    pinnedIssues(first: 3) {
      nodes {
        id
        issue {
          number
          state
          title
        }
      }
    }
  }
}")

  repo_node_id=$(echo "$pinned_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('repository',{}).get('id',''))
" 2>/dev/null)

  if [[ -z "$repo_node_id" ]]; then
    warn "  could not resolve ${repo_full} node ID — skipping"
    continue
  fi

  # ── Unpin resolved issues ─────────────────────────────────────────────────
  if [[ "$unpin_resolved" == "true" ]]; then
    while IFS= read -r pin_entry; do
      pin_id=$(echo "$pin_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      issue_state=$(echo "$pin_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('issue',{}).get('state',''))" 2>/dev/null)
      issue_num=$(echo "$pin_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('issue',{}).get('number',''))" 2>/dev/null)

      if [[ "$issue_state" == "CLOSED" && -n "$pin_id" ]]; then
        info "  unpinning closed issue #${issue_num} from ${repo_full}"
        if [[ "$DRY_RUN" != "true" ]]; then
          gql "mutation { unpinIssue(input: {pinnedIssueId: \"${pin_id}\"}) { issue { number } } }" > /dev/null
        else
          dry "  Would unpin closed issue #${issue_num} from ${repo_full}"
        fi
      fi
    done < <(echo "$pinned_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('repository',{}).get('pinnedIssues',{}).get('nodes',[])
for n in nodes: print(json.dumps(n))
" 2>/dev/null)
  fi

  # ── Pin explicit issue ────────────────────────────────────────────────────
  if [[ -n "$issue_number" ]]; then
    # Resolve issue node ID
    issue_node_id=$(gql "
{
  repository(owner: \"${owner}\", name: \"${repo}\") {
    issue(number: ${issue_number}) {
      id
      title
      state
    }
  }
}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
issue=d.get('data',{}).get('repository',{}).get('issue',{})
print(issue.get('id',''))
" 2>/dev/null)

    if [[ -n "$issue_node_id" ]]; then
      info "  pinning issue #${issue_number} to ${repo_full}"
      if [[ "$DRY_RUN" != "true" ]]; then
        gql "mutation { pinIssue(input: {issueId: \"${issue_node_id}\", repositoryId: \"${repo_node_id}\"}) { issue { number title } } }" \
          | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'errors' in d:
    print(f'[pin-issues] error: {d[\"errors\"]}', file=sys.stderr)
else:
    num=d.get('data',{}).get('pinIssue',{}).get('issue',{}).get('number','?')
    print(f'[pin-issues]   pinned issue #{num}', file=sys.stderr)
" 2>&1 >&2
      else
        dry "  Would pin issue #${issue_number} to ${repo_full}"
      fi
    else
      warn "  issue #${issue_number} not found in ${repo_full}"
    fi

  elif [[ "$auto_pin_top" == "true" ]]; then
    # Auto-pin: find most-reacted open issue not already pinned
    already_pinned=$(echo "$pinned_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('repository',{}).get('pinnedIssues',{}).get('nodes',[])
print(','.join(str(n.get('issue',{}).get('number','')) for n in nodes if n.get('issue',{}).get('state')=='OPEN'))
" 2>/dev/null)

    top_issue=$(gql "
{
  repository(owner: \"${owner}\", name: \"${repo}\") {
    issues(first: 20, states: OPEN, orderBy: {field: COMMENTS, direction: DESC}) {
      nodes {
        id
        number
        title
        reactions { totalCount }
        comments { totalCount }
      }
    }
  }
}" | python3 -c "
import json,sys
already = set('$already_pinned'.split(','))
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('repository',{}).get('issues',{}).get('nodes',[])
# rank by reactions + comments
nodes.sort(key=lambda x: x.get('reactions',{}).get('totalCount',0)+x.get('comments',{}).get('totalCount',0), reverse=True)
for n in nodes:
    if str(n.get('number','')) not in already:
        print(json.dumps({'id': n['id'], 'number': n['number'], 'title': n['title']}))
        break
" 2>/dev/null)

    if [[ -n "$top_issue" ]]; then
      top_id=$(echo "$top_issue" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      top_num=$(echo "$top_issue" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)
      top_title=$(echo "$top_issue" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)

      info "  auto-pinning top issue #${top_num}: ${top_title}"
      if [[ "$DRY_RUN" != "true" ]]; then
        gql "mutation { pinIssue(input: {issueId: \"${top_id}\", repositoryId: \"${repo_node_id}\"}) { issue { number } } }" > /dev/null
      else
        dry "  Would auto-pin issue #${top_num} to ${repo_full}"
      fi
    else
      info "  no unpinned open issues to auto-pin in ${repo_full}"
    fi
  fi

done < <(python3 -c "
import yaml, json
with open('$PIN_CFG') as f:
    cfg = yaml.safe_load(f)
for repo in cfg.get('issues',{}).get('repos',[]) or []:
    print(json.dumps(repo))
" 2>/dev/null)

info "done"
