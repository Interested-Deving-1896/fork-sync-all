#!/usr/bin/env bash
#
# Scan OSP-bound repos in Interested-Deving-1896 for workflow files that do
# not yet exist in fork-sync-all, sanitise them (strip hardcoded org names,
# repo names, secrets, and cron schedules), and open a PR to fork-sync-all
# proposing the sanitised file as a reusable template skeleton.
#
# Flow:
#   For each OSP-bound repo:
#     1. List .github/workflows/*.yml files via the GitHub Contents API.
#     2. Skip any workflow whose basename already exists in fork-sync-all.
#     3. Fetch the raw content and sanitise it.
#     4. Create a branch in fork-sync-all and push the sanitised file.
#     5. Open a PR with context about the source repo and workflow.
#
# Requires:
#   GH_TOKEN      — PAT with repo scope on SOURCE_OWNER and TARGET_REPO
#   SOURCE_OWNER  — org that owns the OSP-bound repos (e.g. Interested-Deving-1896)
#   TARGET_REPO   — owner/repo of fork-sync-all (e.g. Interested-Deving-1896/fork-sync-all)
#   OSP_REPOS     — space-separated list of repo names (set by workflow from config)
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SOURCE_OWNER:?SOURCE_OWNER is required}"
: "${TARGET_REPO:?TARGET_REPO is required}"
: "${OSP_REPOS:?OSP_REPOS is required}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
MAX_PROPOSALS="${MAX_PROPOSALS:-10}"

[[ "$MAX_PROPOSALS" =~ ^[0-9]+$ && "$MAX_PROPOSALS" -ge 1 && "$MAX_PROPOSALS" -le 50 ]] \
  || { echo "ERROR: MAX_PROPOSALS must be an integer from 1 to 50" >&2; exit 1; }

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

proposed=0
skipped=0
failed=0
declare -A reserved_workflow_names=()

# ── helpers ──────────────────────────────────────────────────────────────────

sanitize_token() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

api_get() {
  curl --disable --silent "${AUTH[@]}" "$@"
}

api_post() {
  local url="$1" body="$2"
  curl --disable --silent -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data "$body" "$url"
}

api_put() {
  local url="$1" body="$2"
  curl --disable --silent -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    --data "$body" "$url"
}

# Decode base64 content returned by the GitHub Contents API.
decode_content() {
  echo "$1" | tr -d '\n' | base64 --decode 2>/dev/null
}

# Return the default branch SHA for TARGET_REPO (used as parent for new branches).
get_default_sha() {
  local default_branch
  default_branch=$(api_get "${API}/repos/${TARGET_REPO}" | jq -r '.default_branch // "main"')
  api_get "${API}/repos/${TARGET_REPO}/git/ref/heads/${default_branch}" \
    | jq -r '.object.sha'
}

# Check whether a file already exists in TARGET_REPO at the given path.
file_exists_in_target() {
  local path="$1"
  local status
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    "${AUTH[@]}" "${API}/repos/${TARGET_REPO}/contents/${path}")
  [[ "$status" == "200" ]]
}

# Sanitise a workflow file so it is suitable as a generic template skeleton.
#
# Replacements applied (in order):
#   1. Source repo name → ${REPO_NAME}
#   2. All three known org names → ${GITHUB_OWNER} / ${OSP_ORG} / ${OOC_ORG}
#   3. GitLab group path → ${GITLAB_GROUP}
#   4. Hardcoded `repository: ORG/REPO` in checkout steps → ${GITHUB_OWNER}/REPO
#   5. Hardcoded `default:` values containing ORG/REPO strings → placeholder
#   6. `github.repository_owner == 'ORG'` guard expressions → ${GITHUB_OWNER}
#   7. workflow_run trigger names → replaced with a TODO comment
#   8. Cron schedules → annotated with TODO
#   9. Static run-name lines containing project names → removed
#  10. Step names referencing specific repo names → genericised
sanitise_workflow() {
  local content="$1"
  local source_repo="$2"

  # Write to a temp file so sed operates on a file, avoiding shell quoting
  # issues with $ in replacement strings.
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$content" > "$tmp"

  # 1. Source repo name (do first so later passes don't double-substitute)
  sed -i "s/${source_repo}/\${REPO_NAME}/g" "$tmp"

  # 2. Org names — longest/most-specific first to avoid partial matches
  sed -i 's/OpenOS-Project-Ecosystem-OOC/${OOC_ORG}/g' "$tmp"
  sed -i 's/OpenOS-Project-OSP/${OSP_ORG}/g'            "$tmp"
  sed -i 's/OpenOS-Project/${OSP_ORG}/g'                "$tmp"
  sed -i "s/${SOURCE_OWNER}/\${GITHUB_OWNER}/g"         "$tmp"

  # 3. GitLab group path
  sed -i 's/openos-project/${GITLAB_GROUP}/g' "$tmp"

  # 4. `repository: ORG/repo` in checkout steps — catch any remaining
  #    owner/repo pairs that survived step 2 (e.g. other hardcoded owners)
  sed -i -E 's|(repository:[[:space:]]+)[^/$][^/]*/([^[:space:]]+)|\1${GITHUB_OWNER}/\2|g' "$tmp"

  # 5. `default:` values that still contain a bare ORG/repo token
  #    (catches things like: default: "SomeOrg/some-repo")
  sed -i -E "s|(default:[[:space:]]+['\"]?)[A-Z][A-Za-z0-9_-]+/([A-Za-z0-9_-]+)(['\"]?)|\1\${GITHUB_OWNER}/\2\3  # TODO: set owner|g" "$tmp"

  # 6. `github.repository_owner == 'ORG'` guard expressions
  sed -i -E "s|github\.repository_owner == '[^']*'|github.repository_owner == '\${GITHUB_OWNER}'|g" "$tmp"

  # 7. workflow_run trigger names — project-specific; replace the entire list
  #    with a TODO placeholder so the reviewer fills it in
  awk '
    /^  workflow_run:/ { in_wr=1 }
    in_wr && /^    workflows:/ {
      print
      print "      # TODO: list the workflow names that should trigger this"
      in_wf_list=1; next
    }
    in_wr && in_wf_list && /^      - / { next }
    in_wr && in_wf_list && !/^      - / { in_wf_list=0 }
    { print }
  ' "$tmp" > "${tmp}.awk" && mv "${tmp}.awk" "$tmp"

  # 8. Cron schedules — annotate rather than remove so the reviewer sees them
  sed -i -E 's/^([[:space:]]*- cron: .*)$/\1  # TODO: set schedule for your project/' "$tmp"

  # 9. Static run-name lines containing project-specific arrow notation or
  #    known project keywords (dynamic inputs.* run-names are kept)
  grep -v -E '^run-name:.*→|^run-name:.*(penguins|lts|btrfs|eggs)' "$tmp" > "${tmp}.grep" \
    && mv "${tmp}.grep" "$tmp"

  # 10. Step names that reference specific repo names — genericise.
  #     Uses / delimiter (not |) to avoid ERE treating | as alternation in
  #     the replacement string, and a two-pass approach to avoid ${} in the
  #     sed replacement (which triggers "unknown option" in GNU sed ERE mode).
  sed -i -E 's/(- name: .*(Checkout|Sync|Push|Pull|Clone) )[A-Za-z][A-Za-z0-9_-]*/\1REPO_NAME_PLACEHOLDER/g' "$tmp"
  sed -i 's/REPO_NAME_PLACEHOLDER/${REPO_NAME}/g' "$tmp"

  cat "$tmp"
  rm -f "$tmp"
}

# Create a branch in TARGET_REPO pointing at the given SHA.
create_branch() {
  local branch="$1" sha="$2"
  local body
  body=$(jq -n --arg ref "refs/heads/${branch}" --arg sha "$sha" \
    '{ref: $ref, sha: $sha}')
  api_post "${API}/repos/${TARGET_REPO}/git/refs" "$body" | jq -r '.ref // empty'
}

# Commit a file to TARGET_REPO on the given branch.
commit_file() {
  local path="$1" content_b64="$2" branch="$3" message="$4"
  local body
  body=$(jq -n \
    --arg message "$message" \
    --arg content "$content_b64" \
    --arg branch "$branch" \
    '{message: $message, content: $content, branch: $branch}')
  api_put "${API}/repos/${TARGET_REPO}/contents/${path}" "$body" \
    | jq -r '.content.name // empty'
}

# Open a PR in TARGET_REPO.
open_pr() {
  local head="$1" title="$2" body="$3"
  local default_branch
  default_branch=$(api_get "${API}/repos/${TARGET_REPO}" | jq -r '.default_branch // "main"')
  local pr_body
  pr_body=$(jq -n \
    --arg title "$title" \
    --arg head "$head" \
    --arg base "$default_branch" \
    --arg body "$body" \
    '{title: $title, head: $head, base: $base, body: $body, draft: true}')
  api_post "${API}/repos/${TARGET_REPO}/pulls" "$pr_body" | jq -r '.html_url // empty'
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "upstream-workflow-proposal: scanning OSP-bound repos in ${SOURCE_OWNER}"
echo "  target: ${TARGET_REPO}"
[[ "$DRY_RUN" == "true" ]] && echo "  dry-run: no PRs will be opened"

default_sha=$(get_default_sha)
if [[ -z "$default_sha" ]]; then
  echo "ERROR: could not resolve default branch SHA for ${TARGET_REPO}" >&2
  exit 1
fi

for repo in $OSP_REPOS; do
    budget_check "${repo}" || break
  # Apply optional name filter
  if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  # List workflow files in the source repo
  workflows_json=$(api_get "${API}/repos/${SOURCE_OWNER}/${repo}/contents/.github/workflows" 2>/dev/null)
  if ! echo "$workflows_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    # Repo has no .github/workflows directory — skip silently
    continue
  fi

  while IFS= read -r wf_entry; do
    wf_name=$(echo "$wf_entry" | jq -r '.name')
    wf_download_url=$(echo "$wf_entry" | jq -r '.download_url // empty')

    [[ -z "$wf_name" || -z "$wf_download_url" ]] && continue

    # A basename maps to one target path. Multiple source repositories often
    # carry unrelated ci.yml/release.yml files; proposing all of them creates
    # mutually exclusive PR fan-out. Keep only the first candidate in a scan
    # and report later collisions.
    if [[ -n "${reserved_workflow_names[$wf_name]:-}" ]]; then
      echo "  collision: ${repo}/${wf_name} skipped; already represented by ${reserved_workflow_names[$wf_name]}"
      (( skipped++ )) || true
      continue
    fi
    reserved_workflow_names["$wf_name"]="$repo"

    target_path=".github/workflows/${wf_name}"

    # Skip if the workflow already exists in fork-sync-all
    if file_exists_in_target "$target_path"; then
      (( skipped++ )) || true
      continue
    fi

    echo "  found new workflow: ${repo}/${wf_name}"

    # Fetch raw content
    raw_content=$(curl --disable --silent \
      -H "Authorization: token ${GH_TOKEN}" \
      "$wf_download_url")

    if [[ -z "$raw_content" ]]; then
      echo "  WARNING: could not fetch ${repo}/${wf_name} — skipping" >&2
      (( failed++ )) || true
      continue
    fi

    # Sanitise
    sanitised=$(sanitise_workflow "$raw_content" "$repo")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] would propose: ${wf_name} (from ${repo})"
      (( proposed++ )) || true
      continue
    fi

    if (( proposed >= MAX_PROPOSALS )); then
      echo "  proposal limit reached (${MAX_PROPOSALS}); remaining candidates deferred"
      break 2
    fi

    # Create a branch for this proposal
    branch="upstream-workflow/${repo}/${wf_name%.yml}"
    branch_ref=$(create_branch "$branch" "$default_sha")
    if [[ -z "$branch_ref" ]]; then
      echo "  WARNING: could not create branch ${branch} — skipping" >&2
      (( failed++ )) || true
      continue
    fi

    # Commit the sanitised workflow
    content_b64=$(echo "$sanitised" | base64 -w 0)
    commit_msg="proposal: add ${wf_name} skeleton (from ${SOURCE_OWNER}/${repo})"
    committed=$(commit_file "$target_path" "$content_b64" "$branch" "$commit_msg")
    if [[ -z "$committed" ]]; then
      echo "  WARNING: could not commit ${wf_name} to ${branch} — skipping" >&2
      (( failed++ )) || true
      continue
    fi

    # Open PR
    pr_title="Proposal: add \`${wf_name}\` skeleton"
    pr_body="## Upstream workflow proposal

**Source:** \`${SOURCE_OWNER}/${repo}/.github/workflows/${wf_name}\`

This workflow was detected in an OSP-bound repo and does not yet exist in \`fork-sync-all\`.
The file has been sanitised:
- Hardcoded org/repo names replaced with generic placeholders
- Cron schedules marked with \`# TODO\` comments
- Project-specific \`run-name\` lines removed

**Review checklist before merging:**
- [ ] Workflow is genuinely reusable across projects (not repo-specific logic)
- [ ] No hardcoded repo or org names remain in \`run:\` shell blocks (sanitisation covers \`env:\`, \`with:\`, and \`default:\` fields but not inline shell strings)
- [ ] Cron schedule is appropriate for a template (or removed entirely)
- [ ] \`workflow_run:\` trigger names updated or removed (replaced with TODO by sanitisation)
- [ ] Add to the allowlist in \`scripts/validate-workflows.sh\`
"
    pr_url=$(open_pr "$branch" "$pr_title" "$pr_body")
    if [[ -n "$pr_url" ]]; then
      echo "  Draft PR opened: ${pr_url}"
      (( proposed++ )) || true
    else
      echo "  WARNING: PR creation failed for ${wf_name}" >&2
      (( failed++ )) || true
    fi

  done < <(echo "$workflows_json" | jq -c '.[] | select(.type == "file")')
done

echo ""
echo "upstream-workflow-proposal: done — proposed=${proposed} skipped=${skipped} failed=${failed}"

[[ "$failed" -gt 0 ]] && exit 1
budget_report
exit 0
