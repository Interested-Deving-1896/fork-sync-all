#!/usr/bin/env bash
#
# trigger-readme-update.sh
#
# Triggers update-readmes.yml for all OSP-bound repos (mirror + full + infra-core
# profiles) to fill in placeholder AI sections and inject any missing sections.
#
# ── Dev utility ───────────────────────────────────────────────────────────────
# This is a local dev tool — not called by any workflow. Run it manually
# after a rate-limit reset to batch-dispatch README updates across all
# OSP-bound repos without having to trigger each one individually from
# the GitHub Actions UI.
#
# Run this after the GitHub API rate limit resets (check with: gh api rate_limit).
#
# Usage:
#   GH_TOKEN=ghp_... bash scripts/trigger-readme-update.sh [--dry-run]
#
# With --dry-run: triggers the workflow in dry_run mode (detects stale sections
# without writing changes — useful to audit scope first).
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

DRY_RUN="false"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

OWNER="Interested-Deving-1896"
REPO="fork-sync-all"
WORKFLOW="update-readmes.yml"
API="https://api.github.com"

# ── Check rate limit first ────────────────────────────────────────────────────

echo "Checking rate limit..."
rate_info=$(curl -s \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/rate_limit")

remaining=$(echo "$rate_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" 2>/dev/null || echo "0")
reset_ts=$(echo "$rate_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['reset'])" 2>/dev/null || echo "0")
reset_human=$(date -d "@${reset_ts}" 2>/dev/null || date -r "${reset_ts}" 2>/dev/null || echo "unknown")

echo "  REST API remaining: ${remaining}/5000"
echo "  Resets at: ${reset_human}"

if [[ "$remaining" -lt 10 ]]; then
  echo ""
  echo "Rate limit too low (${remaining} remaining). Wait until ${reset_human} and retry."
  exit 1
fi

# ── Build repo list from template-consumers.yml ───────────────────────────────

echo ""
echo "Reading OSP-bound repos from config/template-consumers.yml..."

mapfile -t OSP_REPOS < <(python3 -c "
import sys

with open('config/template-consumers.yml') as f:
    content = f.read()

consumers = []
current = {}
for line in content.splitlines():
    s = line.strip()
    if s.startswith('- name:'):
        if current:
            consumers.append(current)
        current = {'name': s.split(':', 1)[1].strip(), 'profile': 'full'}
    elif s.startswith('profile:') and current:
        current['profile'] = s.split(':', 1)[1].strip()
    elif s.startswith('disabled: true') and current:
        current['disabled'] = True
if current:
    consumers.append(current)

for c in consumers:
    if c.get('disabled'):
        continue
    if c.get('profile', 'full') in ('full', 'mirror', 'infra-core'):
        print(c['name'])
" 2>/dev/null)

echo "  Found ${#OSP_REPOS[@]} OSP-bound repos"

# ── Trigger workflow in batches ───────────────────────────────────────────────
# update-readmes.yml accepts a space-separated 'repos' input.
# We trigger in batches of 10 to avoid hitting the input length limit and to
# allow each batch to run concurrently without overwhelming the Models API quota.

BATCH_SIZE=10
total=${#OSP_REPOS[@]}
batch_num=0
triggered=0

echo ""
[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN MODE — workflow will detect but not write changes"
echo "Triggering ${WORKFLOW} in batches of ${BATCH_SIZE}..."
echo ""

for (( i=0; i<total; i+=BATCH_SIZE )); do
  batch=("${OSP_REPOS[@]:$i:$BATCH_SIZE}")
  repos_input="${batch[*]}"
  (( batch_num++ ))

  echo "  Batch ${batch_num}: ${repos_input}"

  payload=$(python3 -c "
import json, sys
print(json.dumps({
  'ref': 'main',
  'inputs': {
    'repos': '${repos_input}',
    'priority_only': 'false',
    'dry_run': '${DRY_RUN}',
    'force_rewrite': 'true'
  }
}))
")

  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/repos/${OWNER}/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "$payload")

  http_code=$(echo "$response" | tail -1)

  if [[ "$http_code" == "204" ]]; then
    echo "    ✅ Triggered (HTTP 204)"
    (( triggered++ ))
  else
    body=$(echo "$response" | sed '$d')
    echo "    ❌ Failed (HTTP ${http_code}): $(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null || echo "$body")"
  fi

  # Pace batches — avoid hammering the dispatch endpoint
  if (( i + BATCH_SIZE < total )); then
    echo "    Waiting 5s before next batch..."
    sleep 5
  fi
done

echo ""
echo "========================================"
echo "  README update trigger complete"
echo "  Repos targeted: ${total}"
echo "  Batches triggered: ${triggered}/${batch_num}"
[[ "$DRY_RUN" == "true" ]] && echo "  Mode: DRY RUN (no writes)"
echo ""
echo "  Monitor runs at:"
echo "  https://github.com/${OWNER}/${REPO}/actions/workflows/${WORKFLOW}"
echo "========================================"
