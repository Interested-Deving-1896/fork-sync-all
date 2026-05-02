#!/usr/bin/env bash
#
# Scans repos across multiple owners/orgs for failed GitHub Actions runs,
# fetches error details, sends them to an LLM for analysis, and applies
# fixes automatically when possible.
#
# Requires: GH_TOKEN (PAT with repo, models:read, admin:org scope)
#           SCAN_OWNERS (space-separated list of users/orgs to scan)
#
set -o pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SCAN_OWNERS:?SCAN_OWNERS is required}"

API="https://api.github.com"

# Repos the resolver must never commit to directly. These are repos where
# automated commits cause mirror cascade loops or have their own CI pipelines
# that should only be fixed manually or via their own upstream workflow.
EXCLUDED_REPOS=(
  "Interested-Deving-1896/incus-windows-toolkit"
  "OpenOS-Project-OSP/incus-windows-toolkit"
  "OpenOS-Project-Ecosystem-OOC/incus-windows-toolkit"
)

is_excluded() {
  local repo="$1"
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$excluded" ]] && return 0
  done
  return 1
}
MODELS_API="https://models.github.ai/inference"
MODEL="openai/gpt-4o-mini"
PER_PAGE=100

total_scanned=0
total_failures=0
total_fixed=0
total_unfixable=0

# ── helpers ──────────────────────────────────────────────────────────────────

# ── GitHub API helper with primary + secondary rate-limit handling ────────────
# Retries on 403/429, reads X-RateLimit-Reset from response headers to sleep
# until the window resets rather than using a fixed backoff.
# Max 3 attempts; returns non-zero only after all retries are exhausted.
#
# GitHub rate limits relevant to this script:
#   Primary (REST):   5 000 req/hr per token  — resets on the hour
#   Secondary:        burst/concurrency limit  — typically a 60s cooldown
#   GitHub Models:    separate quota; 429 with Retry-After header when exceeded
#
_RL_HEADER_FILE=$(mktemp)
trap 'rm -f "$_RL_HEADER_FILE"' EXIT

gh_api() {
  local method="$1" url="$2"
  shift 2
  local max_retries=3 attempt=0

  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$_RL_HEADER_FILE" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        echo "$body"
        return 1
      fi
      local reset now wait_seconds
      reset=$(grep -i "x-ratelimit-reset:" "$_RL_HEADER_FILE" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}')
      now=$(date +%s)
      wait_seconds=$(( ${reset:-0} - now + 5 ))
      if [[ -n "$reset" && "$wait_seconds" -gt 0 && "$wait_seconds" -lt 3700 ]]; then
        echo "  [rate-limit] HTTP ${http_code} — sleeping ${wait_seconds}s until reset (attempt ${attempt}/${max_retries})" >&2
        sleep "$wait_seconds"
      else
        echo "  [rate-limit] HTTP ${http_code} — backing off 60s (attempt ${attempt}/${max_retries})" >&2
        sleep 60
      fi
      continue
    fi

    echo "$body"
    [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] || return 1
    return 0
  done
}

gh_api_ok() {
  local response="$1"
  local code
  code=$(echo "$response" | tail -1)
  [[ "$code" -ge 200 && "$code" -lt 300 ]]
}

gh_api_body() {
  echo "$1" | sed '$d'
}

llm_ask() {
  # GitHub Models rate limits:
  #   - Quota varies by model tier; gpt-4o-mini is the most permissive
  #   - 429 responses include a Retry-After header (seconds to wait)
  #   - On quota exhaustion the response body contains "rate limit" or "quota"
  local system_prompt="$1" user_prompt="$2"
  local payload
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg sys "$system_prompt" \
    --arg usr "$user_prompt" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: $usr}
      ],
      temperature: 0.1,
      max_tokens: 3000
    }')

  local max_retries=3 attempt=0
  local _models_header
  _models_header=$(mktemp)

  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -X POST "${MODELS_API}/chat/completions" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      -D "$_models_header" \
      -d "$payload" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        echo "  [models-rate-limit] GitHub Models quota exhausted after ${max_retries} retries" >&2
        rm -f "$_models_header"
        echo ""
        return 1
      fi
      local retry_after
      retry_after=$(grep -i "retry-after:" "$_models_header" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}')
      local wait_seconds="${retry_after:-60}"
      echo "  [models-rate-limit] HTTP 429 — sleeping ${wait_seconds}s (attempt ${attempt}/${max_retries})" >&2
      sleep "$wait_seconds"
      continue
    fi

    rm -f "$_models_header"
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null
      return 0
    else
      echo ""
      return 1
    fi
  done
}

# ── scanner ──────────────────────────────────────────────────────────────────

get_repos_for_owner() {
  local owner="$1"
  local page=1

  # Try as org first, fall back to user
  while true; do
    local response
    response=$(gh_api GET "${API}/orgs/${owner}/repos?type=all&per_page=${PER_PAGE}&page=${page}")
    if ! gh_api_ok "$response"; then
      # Try as user
      response=$(gh_api GET "${API}/users/${owner}/repos?type=owner&per_page=${PER_PAGE}&page=${page}")
      if ! gh_api_ok "$response"; then
        break
      fi
    fi

    local body
    body=$(gh_api_body "$response")
    local count
    count=$(echo "$body" | jq 'length' 2>/dev/null) || break
    [[ -z "$count" || "$count" == "0" ]] && break

    echo "$body" | jq -r '.[].full_name' 2>/dev/null
    page=$(( page + 1 ))
  done
}

get_recent_failures() {
  local repo="$1"
  local response
  response=$(gh_api GET "${API}/repos/${repo}/actions/runs?status=failure&per_page=5")
  if gh_api_ok "$response"; then
    gh_api_body "$response"
  else
    echo '{"workflow_runs":[]}'
  fi
}

get_run_jobs() {
  local repo="$1" run_id="$2"
  local response
  response=$(gh_api GET "${API}/repos/${repo}/actions/runs/${run_id}/jobs")
  if gh_api_ok "$response"; then
    gh_api_body "$response"
  else
    echo '{"jobs":[]}'
  fi
}

get_job_logs() {
  local repo="$1" job_id="$2"
  # Job logs endpoint returns raw text
  curl -s -L \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${repo}/actions/jobs/${job_id}/logs" 2>/dev/null | tail -80
}

get_workflow_file() {
  local repo="$1" workflow_path="$2" branch="$3"
  local response
  response=$(gh_api GET "${API}/repos/${repo}/contents/${workflow_path}?ref=${branch}")
  if gh_api_ok "$response"; then
    gh_api_body "$response" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null
  else
    echo ""
  fi
}

# ── fixer ────────────────────────────────────────────────────────────────────

apply_fix() {
  local repo="$1" branch="$2" file_path="$3" new_content="$4" commit_msg="$5"

  # Get current file SHA
  local response
  response=$(gh_api GET "${API}/repos/${repo}/contents/${file_path}?ref=${branch}")
  if ! gh_api_ok "$response"; then
    echo "      Could not read ${file_path} for update"
    return 1
  fi

  local sha
  sha=$(gh_api_body "$response" | jq -r '.sha // empty' 2>/dev/null)
  if [[ -z "$sha" ]]; then
    echo "      Could not get SHA for ${file_path}"
    return 1
  fi

  local encoded_content
  encoded_content=$(echo "$new_content" | base64 -w 0)

  local payload
  payload=$(jq -n \
    --arg msg "$commit_msg" \
    --arg content "$encoded_content" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{message: $msg, content: $content, sha: $sha, branch: $branch}')

  response=$(gh_api PUT "${API}/repos/${repo}/contents/${file_path}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if gh_api_ok "$response"; then
    echo "      Fix committed to ${branch}"
    return 0
  else
    echo "      Failed to commit fix"
    gh_api_body "$response" | jq -r '.message // empty' 2>/dev/null | head -3
    return 1
  fi
}

analyze_and_fix() {
  local repo="$1" run_id="$2" run_name="$3" branch="$4" workflow_path="$5"

  echo "    Fetching job details..."
  local jobs_json
  jobs_json=$(get_run_jobs "$repo" "$run_id")

  local failed_job_id failed_step
  failed_job_id=$(echo "$jobs_json" | jq -r '[.jobs[] | select(.conclusion == "failure")][0].id // empty' 2>/dev/null)

  if [[ -z "$failed_job_id" ]]; then
    echo "    No failed jobs found in run"
    return 1
  fi

  # Get annotations (error messages)
  local annotations
  annotations=$(echo "$jobs_json" | jq -r '
    [.jobs[] | select(.conclusion == "failure") | .steps[]? |
     select(.conclusion == "failure") |
     "Step: \(.name) — Status: \(.conclusion)"] | join("\n")' 2>/dev/null)

  echo "    Fetching logs..."
  local logs
  logs=$(get_job_logs "$repo" "$failed_job_id")

  echo "    Fetching workflow file..."
  local workflow_content
  workflow_content=$(get_workflow_file "$repo" "$workflow_path" "$branch")

  if [[ -z "$workflow_content" ]]; then
    echo "    Could not fetch workflow file at ${workflow_path}"
    return 1
  fi

  # Truncate logs to fit in context
  local truncated_logs
  truncated_logs=$(echo "$logs" | tail -60)

  echo "    Asking AI for analysis..."
  local system_prompt
  system_prompt='You are a GitHub Actions CI/CD expert. Analyze the failed workflow and provide a fix.

RULES:
- If you can fix the workflow YAML file, respond with EXACTLY this format:
  FIX_AVAILABLE: yes
  FILE: <path to file to fix>
  COMMIT_MSG: <one-line commit message>
  EXPLANATION: <one-line explanation>
  ---FIXED_CONTENT_START---
  <complete fixed file content>
  ---FIXED_CONTENT_END---

- If the fix requires something outside the workflow file (e.g., missing secrets, external service down, code bugs), respond with:
  FIX_AVAILABLE: no
  EXPLANATION: <what needs to be done manually>

- Only fix the workflow YAML file. Do not invent new files.
- Preserve all existing functionality. Make minimal changes.
- Common fixes: missing permissions, secrets in job-level if, wrong Node/Python version, missing setup steps.'

  local user_prompt
  user_prompt="Repository: ${repo}
Branch: ${branch}
Workflow: ${workflow_path}
Run name: ${run_name}

Failed steps:
${annotations}

Last 60 lines of logs:
${truncated_logs}

Current workflow file content:
\`\`\`yaml
${workflow_content}
\`\`\`

Analyze the failure and provide a fix if possible."

  local ai_response
  ai_response=$(llm_ask "$system_prompt" "$user_prompt")

  if [[ -z "$ai_response" ]]; then
    echo "    AI analysis failed (rate limit or API error)"
    return 1
  fi

  local fix_available
  fix_available=$(echo "$ai_response" | grep -oP 'FIX_AVAILABLE:\s*\K\S+' | head -1)

  local explanation
  explanation=$(echo "$ai_response" | grep -oP 'EXPLANATION:\s*\K.*' | head -1)

  if [[ "$fix_available" == "yes" ]]; then
    local commit_msg
    commit_msg=$(echo "$ai_response" | grep -oP 'COMMIT_MSG:\s*\K.*' | head -1)
    commit_msg="${commit_msg:-fix: auto-resolve CI failure}"

    local fixed_content
    fixed_content=$(echo "$ai_response" | sed -n '/---FIXED_CONTENT_START---/,/---FIXED_CONTENT_END---/p' | sed '1d;$d')

    if [[ -z "$fixed_content" ]]; then
      echo "    AI suggested a fix but output was malformed"
      echo "    Explanation: ${explanation}"
      return 1
    fi

    echo "    AI fix: ${explanation}"
    echo "    Applying fix..."

    # Append co-author
    # [skip ci] prevents the fix commit from triggering new CI runs and
    # generating a notification feedback loop back into this resolver.
    commit_msg="${commit_msg} [skip ci]

Co-authored-by: AI Resolver <no-reply@github.com>
Co-authored-by: Ona <no-reply@ona.com>"

    if apply_fix "$repo" "$branch" "$workflow_path" "$fixed_content" "$commit_msg"; then
      total_fixed=$(( total_fixed + 1 ))
      close_watchdog_issues "$run_id" "$repo" "$explanation"
      return 0
    else
      total_unfixable=$(( total_unfixable + 1 ))
      return 1
    fi
  else
    echo "    Cannot auto-fix: ${explanation}"
    total_unfixable=$(( total_unfixable + 1 ))
    return 1
  fi
}

# ── notifications pass ───────────────────────────────────────────────────────
# Processes unread CI failure notifications first — faster and targeted.
# Successfully fixed notifications are dismissed automatically.
# Thread IDs that were already handled are tracked to avoid double-processing
# in the full scan below.

declare -A NOTIF_HANDLED_REPOS   # repo full_name → 1 if already processed

dismiss_notification() {
  local thread_id="$1"
  curl -s -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/notifications/threads/${thread_id}" \
    > /dev/null 2>&1 || true
}

# close_watchdog_issues closes any open ci-watchdog issues in WATCHDOG_REPO
# that reference the given run ID, leaving a comment explaining the resolution.
# WATCHDOG_REPO defaults to Interested-Deving-1896/fork-sync-all.
WATCHDOG_REPO="${WATCHDOG_REPO:-Interested-Deving-1896/fork-sync-all}"

close_watchdog_issues() {
  local run_id="$1" repo="$2" explanation="$3"

  local response
  response=$(gh_api GET \
    "${API}/repos/${WATCHDOG_REPO}/issues?labels=ci-watchdog&state=open&per_page=50")
  gh_api_ok "$response" || return 0

  local issues
  issues=$(gh_api_body "$response")

  # Find issues whose body references this run ID
  local matched_numbers
  matched_numbers=$(echo "$issues" | \
    jq -r --arg run "$run_id" \
    '.[] | select(.body | test($run)) | .number' 2>/dev/null)

  [[ -z "$matched_numbers" ]] && return 0

  local comment
  comment="Auto-resolved by \`resolve-failures.sh\`.

**Run:** https://github.com/${repo}/actions/runs/${run_id}
**Fix applied:** ${explanation}

The workflow has been patched and the run failure should not recur."

  while IFS= read -r issue_number; do
    [[ -z "$issue_number" ]] && continue

    # Post comment
    local comment_payload
    comment_payload=$(jq -n --arg body "$comment" '{body: $body}')
    gh_api POST \
      "${API}/repos/${WATCHDOG_REPO}/issues/${issue_number}/comments" \
      -H "Content-Type: application/json" \
      -d "$comment_payload" > /dev/null

    # Close with reason "completed"
    local close_payload
    close_payload=$(jq -n '{state: "closed", state_reason: "completed"}')
    local close_response
    close_response=$(gh_api PATCH \
      "${API}/repos/${WATCHDOG_REPO}/issues/${issue_number}" \
      -H "Content-Type: application/json" \
      -d "$close_payload")

    if gh_api_ok "$close_response"; then
      echo "    Closed watchdog issue #${issue_number} in ${WATCHDOG_REPO}"
    else
      echo "    Could not close watchdog issue #${issue_number}"
    fi
  done <<< "$matched_numbers"
}

resolve_notifications() {
  echo "========================================"
  echo "  Notifications pass"
  echo "========================================"

  local page=1
  local notif_total=0
  local notif_fixed=0
  local notif_unfixable=0

  while true; do
    local response
    response=$(gh_api GET "${API}/notifications?all=false&per_page=50&page=${page}")
    gh_api_ok "$response" || break

    local body
    body=$(gh_api_body "$response")
    local count
    count=$(echo "$body" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break

    while IFS=$'\t' read -r thread_id repo_full reason subject_type subject_url; do
      [[ -z "$thread_id" ]] && continue

      # Only care about CI activity failures
      [[ "$reason" != "ci_activity" ]] && { dismiss_notification "$thread_id"; continue; }
      [[ "$subject_type" != "CheckSuite" ]] && { dismiss_notification "$thread_id"; continue; }

      notif_total=$(( notif_total + 1 ))
      echo ""
      echo "  NOTIFICATION: ${repo_full}"
      echo "    Thread: ${thread_id}"

      # Extract run ID from the latest_comment_url or subject URL
      local run_id=""
      run_id=$(echo "$subject_url" | grep -oE '[0-9]{8,}' | tail -1)

      if [[ -z "$run_id" ]]; then
        echo "    Could not extract run ID — dismissing"
        dismiss_notification "$thread_id"
        continue
      fi

      # Fetch the run to get workflow path and branch
      local run_response
      run_response=$(gh_api GET "${API}/repos/${repo_full}/actions/runs/${run_id}")
      if ! gh_api_ok "$run_response"; then
        echo "    Run ${run_id} not found — dismissing"
        dismiss_notification "$thread_id"
        continue
      fi

      local run_body
      run_body=$(gh_api_body "$run_response")
      local conclusion branch workflow_path run_name
      conclusion=$(echo "$run_body" | jq -r '.conclusion // empty')
      branch=$(echo "$run_body" | jq -r '.head_branch // empty')
      workflow_path=$(echo "$run_body" | jq -r '.path // empty')
      run_name=$(echo "$run_body" | jq -r '.name // empty')

      if [[ "$conclusion" != "failure" ]]; then
        echo "    Run ${run_id} conclusion is '${conclusion}' — dismissing"
        dismiss_notification "$thread_id"
        continue
      fi

      if is_excluded "$repo_full"; then
        echo "    Excluded repo — dismissing"
        dismiss_notification "$thread_id"
        continue
      fi

      echo "    Workflow: ${run_name} (${workflow_path})"
      echo "    Branch:   ${branch}"

      total_failures=$(( total_failures + 1 ))

      if analyze_and_fix "$repo_full" "$run_id" "$run_name" "$branch" "$workflow_path"; then
        notif_fixed=$(( notif_fixed + 1 ))
        NOTIF_HANDLED_REPOS["$repo_full"]=1
        dismiss_notification "$thread_id"
        echo "    Notification dismissed."
      else
        notif_unfixable=$(( notif_unfixable + 1 ))
        # Still dismiss — we've processed it; the full scan will re-check if needed
        dismiss_notification "$thread_id"
      fi

    done < <(echo "$body" | jq -r '.[] |
      [
        .id,
        .repository.full_name,
        .reason,
        .subject.type,
        .subject.url
      ] | @tsv' 2>/dev/null)

    page=$(( page + 1 ))
    [[ "$count" -lt 50 ]] && break
  done

  echo ""
  echo "  Notifications processed: ${notif_total}"
  echo "  Fixed: ${notif_fixed} | Could not auto-fix: ${notif_unfixable}"
  echo ""
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "========================================"
echo "  CI Failure Resolver"
echo "  Scanning: ${SCAN_OWNERS}"
echo "========================================"
echo ""

resolve_notifications
echo ""

for owner in $SCAN_OWNERS; do
  echo "Scanning ${owner}..."
  mapfile -t repos < <(get_repos_for_owner "$owner")
  echo "  Found ${#repos[@]} repos"

  for repo in "${repos[@]}"; do
    [[ -z "$repo" ]] && continue

    if is_excluded "$repo"; then
      echo "  Skipping excluded repo: ${repo}"
      continue
    fi

    total_scanned=$(( total_scanned + 1 ))

    failures_json=$(get_recent_failures "$repo")
    failure_count=$(echo "$failures_json" | jq '.total_count // 0' 2>/dev/null)

    [[ "$failure_count" == "0" || -z "$failure_count" ]] && continue

    # Only process the most recent failure per workflow to avoid duplicate fixes
    mapfile -t recent_runs < <(echo "$failures_json" | jq -r '
      [.workflow_runs | group_by(.workflow_id)[] | sort_by(.created_at) | last] |
      .[] | "\(.id)\t\(.name)\t\(.head_branch)\t\(.path)"' 2>/dev/null)

    for run_line in "${recent_runs[@]}"; do
      [[ -z "$run_line" ]] && continue

      run_id=$(echo "$run_line" | cut -f1)
      run_name=$(echo "$run_line" | cut -f2)
      run_branch=$(echo "$run_line" | cut -f3)
      workflow_path=$(echo "$run_line" | cut -f4)

      total_failures=$(( total_failures + 1 ))
      echo ""
      echo "  FAILURE: ${repo}"
      echo "    Workflow: ${run_name}"
      echo "    Branch: ${run_branch}"
      echo "    Run ID: ${run_id}"

      analyze_and_fix "$repo" "$run_id" "$run_name" "$run_branch" "$workflow_path" || true
    done
  done
  echo ""
done

echo ""
echo "========================================"
echo "  Resolver complete"
echo "  Repos scanned:   ${total_scanned}"
echo "  Failures found:  ${total_failures}"
echo "  Auto-fixed:      ${total_fixed}"
echo "  Need manual fix: ${total_unfixable}"
echo "========================================"

# Exit 0 — failures to fix are informational, not errors
exit 0
