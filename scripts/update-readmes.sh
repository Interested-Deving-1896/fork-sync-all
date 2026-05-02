#!/usr/bin/env bash
#
# Updates AI-owned sections of README.md files across all Interested-Deving-1896
# repos. Human-owned sections (between <!-- HUMAN:start --> / <!-- HUMAN:end -->
# markers, or any section not wrapped in AI markers) are never modified.
#
# AI-owned sections are wrapped with:
#   <!-- AI:start:SECTION_NAME -->
#   ...content...
#   <!-- AI:end:SECTION_NAME -->
#
# Sections: what-it-does, architecture, ci, mirror-chain
#
# Also updates repo description and topics via the GitHub API.
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with repo + models:read scopes
#   GITHUB_OWNER  — org to scan (Interested-Deving-1896)
#
# Optional env vars:
#   CHANGED_REPOS — space-separated list of repos to process (push trigger mode)
#                   if empty, all repos are scanned (daily mode)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

GH_API="https://api.github.com"
MODELS_API="https://models.github.ai/inference"
MODEL="openai/gpt-4o"

AI_START="<!-- AI:start:"
AI_END="<!-- AI:end:"
MARKER_CLOSE=" -->"

info()  { echo "[update-readmes] $*"; }
warn()  { echo "[warn] $*" >&2; }

# ── LLM ──────────────────────────────────────────────────────────────────────

llm_ask() {
  local system_prompt="$1" user_prompt="$2" max_tokens="${3:-2000}"
  local payload response

  payload=$(jq -n \
    --arg model  "$MODEL" \
    --arg sys    "$system_prompt" \
    --arg usr    "$user_prompt" \
    --argjson mt "$max_tokens" \
    '{model:$model,messages:[{role:"system",content:$sys},{role:"user",content:$usr}],temperature:0.2,max_tokens:$mt}')

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${MODELS_API}/chat/completions" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)

  local http_code body
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null
  else
    warn "LLM call failed (HTTP ${http_code})"
    echo ""
  fi
}

# ── GitHub helpers ────────────────────────────────────────────────────────────

gh_get() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

gh_patch() {
  local url="$1"; shift
  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

get_file_content() {
  local owner="$1" repo="$2" path="$3"
  local meta
  meta=$(gh_get "${GH_API}/repos/${owner}/${repo}/contents/${path}" 2>/dev/null) || return 1
  echo "$meta" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null
}

get_file_sha() {
  local owner="$1" repo="$2" path="$3"
  gh_get "${GH_API}/repos/${owner}/${repo}/contents/${path}" 2>/dev/null \
    | jq -r '.sha // empty'
}

commit_file() {
  local owner="$1" repo="$2" path="$3" message="$4" content_b64="$5" sha="$6"
  local payload
  if [ -n "$sha" ]; then
    payload=$(jq -n --arg m "$message" --arg c "$content_b64" --arg s "$sha" \
      '{message:$m,content:$c,sha:$s}')
  else
    payload=$(jq -n --arg m "$message" --arg c "$content_b64" \
      '{message:$m,content:$c}')
  fi
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${owner}/${repo}/contents/${path}" \
    -d "$payload" > /dev/null
}

# ── Repo context collector ────────────────────────────────────────────────────

collect_repo_context() {
  local owner="$1" repo="$2"
  local context=""

  # Repo metadata
  local meta
  meta=$(gh_get "${GH_API}/repos/${owner}/${repo}" 2>/dev/null) || return 1
  local description language
  description=$(echo "$meta" | jq -r '.description // ""')
  language=$(echo "$meta" | jq -r '.language // ""')
  context+="Repository: ${owner}/${repo}\n"
  context+="Description: ${description}\n"
  context+="Primary language: ${language}\n\n"

  # Key files to sample (truncated to keep prompt size manageable)
  local sample_files=(
    "package.json" "Cargo.toml" "go.mod" "pyproject.toml" "setup.py"
    "Makefile" "CMakeLists.txt" "meson.build"
    ".github/workflows" "scripts"
  )

  for f in "${sample_files[@]}"; do
    local content
    content=$(get_file_content "$owner" "$repo" "$f" 2>/dev/null | head -c 2000) || continue
    [ -z "$content" ] && continue
    context+="=== ${f} ===\n${content}\n\n"
  done

  # Workflow list
  local workflows
  workflows=$(gh_get "${GH_API}/repos/${owner}/${repo}/contents/.github/workflows" 2>/dev/null \
    | jq -r '.[].name' 2>/dev/null | tr '\n' ' ') || true
  [ -n "$workflows" ] && context+="Workflows: ${workflows}\n\n"

  # Top-level directory listing
  local tree
  tree=$(gh_get "${GH_API}/repos/${owner}/${repo}/git/trees/HEAD" 2>/dev/null \
    | jq -r '.tree[].path' 2>/dev/null | head -30 | tr '\n' ' ') || true
  [ -n "$tree" ] && context+="Top-level files: ${tree}\n\n"

  echo -e "$context"
}

# ── Section marker helpers ────────────────────────────────────────────────────

extract_ai_section() {
  local content="$1" section="$2"
  local start_marker="${AI_START}${section}${MARKER_CLOSE}"
  local end_marker="${AI_END}${section}${MARKER_CLOSE}"
  echo "$content" | awk "/${start_marker}/{found=1; next} /${end_marker}/{found=0} found{print}"
}

has_ai_section() {
  local content="$1" section="$2"
  echo "$content" | grep -qF "${AI_START}${section}${MARKER_CLOSE}"
}

replace_ai_section() {
  local content="$1" section="$2" new_body="$3"
  local start_marker="${AI_START}${section}${MARKER_CLOSE}"
  local end_marker="${AI_END}${section}${MARKER_CLOSE}"

  # Use awk to replace between markers
  echo "$content" | awk \
    -v start="$start_marker" \
    -v end="$end_marker" \
    -v new_body="$new_body" \
    -v sm="${start_marker}" \
    -v em="${end_marker}" \
    'BEGIN{in_block=0}
     $0 == sm {print sm; print new_body; in_block=1; next}
     $0 == em {print em; in_block=0; next}
     !in_block {print}'
}

inject_ai_section() {
  local content="$1" section="$2" body="$3" after_section="$4"
  local start_marker="${AI_START}${section}${MARKER_CLOSE}"
  local end_marker="${AI_END}${section}${MARKER_CLOSE}"
  local block
  block="${start_marker}
${body}
${end_marker}"

  if [ -n "$after_section" ] && echo "$content" | grep -qF "${AI_END}${after_section}${MARKER_CLOSE}"; then
    # Insert after the named section's end marker
    echo "$content" | awk \
      -v marker="${AI_END}${after_section}${MARKER_CLOSE}" \
      -v block="$block" \
      '{print} $0 == marker {print ""; print block}'
  else
    # Append at end
    echo -e "${content}\n\n${block}"
  fi
}

# ── Per-section generators ────────────────────────────────────────────────────

SYSTEM_PROMPT='You are a technical writer for an open-source infrastructure project.
Write concise, factual README sections in Markdown. No marketing language.
No superlatives. No filler. Output only the requested section content —
no headings, no markers, no preamble. Use present tense.'

generate_what_it_does() {
  local context="$1"
  llm_ask "$SYSTEM_PROMPT" \
    "Write a 2-4 sentence description of what this project does, based on the repo context below.
Focus on the problem it solves and who uses it. No bullet points.

${context}" 500
}

generate_architecture() {
  local context="$1"
  llm_ask "$SYSTEM_PROMPT" \
    "Write an Architecture section for this project's README. Describe the key components,
how they interact, and the directory structure if relevant. Use a short paragraph and/or
a markdown code block for directory trees. Keep it under 20 lines.

${context}" 800
}

generate_ci() {
  local context="$1" owner="$2" repo="$3"
  llm_ask "$SYSTEM_PROMPT" \
    "Write a CI section for this project's README. List the GitHub Actions workflows,
what each does, and any required secrets. Base it on the workflow files in the context.
Keep it under 15 lines.

${context}" 600
}

generate_mirror_chain() {
  local owner="$1" repo="$2"
  cat << EOF
This repo is maintained in [\`${owner}/${repo}\`](https://github.com/${owner}/${repo}) and mirrored through:

\`\`\`
${owner}/${repo}  ──►  OpenOS-Project-OSP/${repo}  ──►  OpenOS-Project-Ecosystem-OOC/${repo}
\`\`\`

Changes flow downstream automatically via the hourly mirror chain in
[\`fork-sync-all\`](https://github.com/${owner}/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to \`${owner}\`.
EOF
}

# ── Description + topics updater ─────────────────────────────────────────────

update_repo_metadata() {
  local owner="$1" repo="$2" context="$3"

  info "  Updating description + topics..."

  local description_prompt
  description_prompt="Write a single sentence (max 120 chars) describing this repo for its GitHub description field.
No punctuation at end. No markdown.

${context}"

  local topics_prompt
  topics_prompt="List 5-8 GitHub topic tags for this repo as a JSON array of lowercase strings with hyphens.
Example: [\"incus\",\"linux\",\"container\"]. Output only the JSON array.

${context}"

  local new_desc new_topics_raw
  new_desc=$(llm_ask "$SYSTEM_PROMPT" "$description_prompt" 100)
  new_topics_raw=$(llm_ask "$SYSTEM_PROMPT" "$topics_prompt" 100)

  # Truncate description to 350 chars (GitHub limit)
  new_desc="${new_desc:0:350}"

  if [ -n "$new_desc" ]; then
    gh_patch "${GH_API}/repos/${owner}/${repo}" \
      -d "{\"description\":$(echo "$new_desc" | jq -Rs .)}" > /dev/null \
      && info "  Description updated." \
      || warn "  Failed to update description."
  fi

  # Validate topics JSON and apply
  if echo "$new_topics_raw" | jq -e 'if type=="array" then . else error end' > /dev/null 2>&1; then
    curl -sf -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "${GH_API}/repos/${owner}/${repo}/topics" \
      -d "{\"names\":${new_topics_raw}}" > /dev/null \
      && info "  Topics updated." \
      || warn "  Failed to update topics."
  fi
}

# ── Main per-repo processor ───────────────────────────────────────────────────

process_repo() {
  local owner="$1" repo="$2"

  info "──────────────────────────────────────────"
  info "${owner}/${repo}"

  # Collect context
  local context
  context=$(collect_repo_context "$owner" "$repo") || {
    warn "  Could not collect context — skipping"
    return 0
  }

  # Get existing README
  local readme_content readme_sha
  readme_content=$(get_file_content "$owner" "$repo" "README.md" 2>/dev/null) || readme_content=""
  readme_sha=$(get_file_sha "$owner" "$repo" "README.md" 2>/dev/null) || readme_sha=""

  if [ -z "$readme_content" ]; then
    info "  No README found — skipping (use create-readmes workflow for new READMEs)"
    return 0
  fi

  local updated_content="$readme_content"
  local changed=false

  # Process each AI-owned section
  for section in "what-it-does" "architecture" "ci" "mirror-chain"; do
    if ! has_ai_section "$updated_content" "$section"; then
      info "  Section '${section}' has no AI markers — skipping (human-owned or absent)"
      continue
    fi

    info "  Regenerating section: ${section}..."
    local new_body=""

    case "$section" in
      what-it-does)  new_body=$(generate_what_it_does "$context") ;;
      architecture)  new_body=$(generate_architecture "$context") ;;
      ci)            new_body=$(generate_ci "$context" "$owner" "$repo") ;;
      mirror-chain)  new_body=$(generate_mirror_chain "$owner" "$repo") ;;
    esac

    if [ -z "$new_body" ]; then
      warn "  LLM returned empty for '${section}' — keeping existing"
      continue
    fi

    local old_body
    old_body=$(extract_ai_section "$updated_content" "$section")

    if [ "$old_body" = "$new_body" ]; then
      info "  Section '${section}' unchanged."
      continue
    fi

    updated_content=$(replace_ai_section "$updated_content" "$section" "$new_body")
    changed=true
    info "  Section '${section}' updated."
  done

  if $changed; then
    local new_b64
    new_b64=$(echo "$updated_content" | base64 -w0)
    commit_file "$owner" "$repo" "README.md" \
      "docs: update AI-owned README sections [skip ci]" \
      "$new_b64" "$readme_sha" \
      && info "  ✅ README committed." \
      || warn "  ❌ Failed to commit README."
  else
    info "  No changes needed."
  fi

  # Always update description + topics
  update_repo_metadata "$owner" "$repo" "$context"
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "========================================"
echo "  README Updater"
echo "  Owner: ${GITHUB_OWNER}"
echo "========================================"
echo ""

if [ -n "${CHANGED_REPOS:-}" ]; then
  info "Push trigger mode — processing: ${CHANGED_REPOS}"
  for repo in $CHANGED_REPOS; do
    process_repo "$GITHUB_OWNER" "$repo"
  done
else
  info "Daily mode — scanning all repos..."
  repos=$(gh_get "${GH_API}/orgs/${GITHUB_OWNER}/repos?per_page=100&sort=pushed" \
    | jq -r '.[].name' 2>/dev/null) || { warn "Failed to list repos"; exit 1; }

  for repo in $repos; do
    process_repo "$GITHUB_OWNER" "$repo"
    sleep 2  # Avoid GitHub Models rate limits
  done
fi

echo ""
info "Done."
