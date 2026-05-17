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
# Sections: what-it-does, architecture, ci, mirror-chain, contributors, origins, resources, license
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

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"

# When true, strip <!-- AI:skip --> before processing so statically-written
# READMEs are migrated to the marker template on this run.
FORCE_REWRITE="${FORCE_REWRITE:-false}"

# When true, run the LTS pass instead of the normal AI pass.
# The LTS pass standardises <!-- LTS:start:* --> / <!-- LTS:end:* --> sections
# (human-owned content) against the current repo state — preserving intent
# but fixing accuracy, completeness, and consistency with AI-owned sections.
LTS_MODE="${LTS_MODE:-false}"

LTS_START="<!-- LTS:start:"
LTS_END="<!-- LTS:end:"

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
  if [[ "$DRY_RUN" == "true" ]]; then
    info "  [DRY_RUN] would commit ${path} to ${owner}/${repo}"
    return 0
  fi
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

# ── License / Origins / Resources generators ─────────────────────────────────

generate_license() {
  local owner="$1" repo="$2"
  # Fetch license from GitHub API — no LLM needed
  local license_data
  license_data=$(curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${owner}/${repo}/license" 2>/dev/null) || license_data=""

  local spdx name html_url
  spdx=$(echo "$license_data" | jq -r '.license.spdx_id // empty' 2>/dev/null)
  name=$(echo "$license_data" | jq -r '.license.name // empty' 2>/dev/null)
  html_url=$(echo "$license_data" | jq -r '.html_url // empty' 2>/dev/null)

  if [[ -n "$spdx" && "$spdx" != "NOASSERTION" ]]; then
    local link="${html_url:-https://github.com/${owner}/${repo}/blob/main/LICENSE}"
    echo "[${spdx}](${link}) © $(date +%Y) [${owner}](https://github.com/${owner})"
  else
    echo "<!-- License not detected — add a LICENSE file to this repo. -->"
  fi
}

generate_origins() {
  local owner="$1" repo="$2"
  # Read dep-graph/origins.md from the repo if it exists — no LLM needed
  local origins_meta
  origins_meta=$(curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${owner}/${repo}/contents/dep-graph/origins.md" 2>/dev/null) || origins_meta=""

  if echo "$origins_meta" | jq -e '.content' > /dev/null 2>&1; then
    local content
    content=$(echo "$origins_meta" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null)
    # Strip the top-level heading (already in the section heading)
    echo "$content" | sed '1{/^# /d}'
  else
    echo "_No dependency graph found. Run \`generate-dep-graph.yml\` to generate \`dep-graph/origins.md\`._"
  fi
}

generate_resources() {
  local owner="$1" repo="$2"
  # Build a links table from known files — no LLM needed
  local base="https://github.com/${owner}/${repo}/blob/main"
  local raw="https://raw.githubusercontent.com/${owner}/${repo}/main"

  # Probe which files exist
  local rows=""
  declare -A RESOURCE_FILES=(
    ["dep-graph/origins.md"]="Dependency graph (Markdown table)"
    ["dep-graph/origins.dot"]="Dependency graph (Graphviz DOT source)"
    ["dep-graph/origins.json"]="Dependency graph (machine-readable JSON)"
    ["registered-imports.json"]="Registered ongoing-sync imports"
    ["config/gitlab-subgroups.yml"]="GitLab subgroup map"
    [".gitlab/merge_request_templates/Default.md"]="GitLab MR template"
  )

  for path in "${!RESOURCE_FILES[@]}"; do
    local desc="${RESOURCE_FILES[$path]}"
    local check
    check=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/repos/${owner}/${repo}/contents/${path}" 2>/dev/null)
    if [[ "$check" == "200" ]]; then
      rows+="| [${path}](${base}/${path}) | ${desc} |\n"
    fi
  done

  if [[ -n "$rows" ]]; then
    echo -e "| File | Description |\n|---|---|\n${rows}"
  else
    echo "_No additional resource files found._"
  fi
}

# ── Badge injection ───────────────────────────────────────────────────────────

BADGE_SVG="https://ona.com/build-with-ona.svg"
BADGE_BASE_URL="https://app.ona.com/#"

badge_line_for() {
  local owner="$1" repo="$2" platform="${3:-github}"
  local target_url
  case "$platform" in
    gitlab) target_url="https://gitlab.com/${owner}/${repo}" ;;
    *)      target_url="https://github.com/${owner}/${repo}" ;;
  esac
  echo "[![Built with Ona](${BADGE_SVG})](${BADGE_BASE_URL}${target_url})"
}

inject_badge_if_missing() {
  local content="$1" owner="$2" repo="$3" platform="${4:-github}"
  # Already has badge — nothing to do
  if echo "$content" | grep -qF "$BADGE_SVG"; then
    echo "$content"
    return 0
  fi
  local badge
  badge=$(badge_line_for "$owner" "$repo" "$platform")
  # Insert badge after the first # heading line
  echo "$content" | awk -v badge="$badge" '
    /^# / && !done { print; print ""; print badge; done=1; next }
    { print }
  '
}

# ── LTS section helpers ───────────────────────────────────────────────────────

extract_lts_section() {
  local content="$1" section="$2"
  local start_marker="${LTS_START}${section}${MARKER_CLOSE}"
  local end_marker="${LTS_END}${section}${MARKER_CLOSE}"
  echo "$content" | awk "/${start_marker}/{found=1; next} /${end_marker}/{found=0} found{print}"
}

has_lts_section() {
  local content="$1" section="$2"
  echo "$content" | grep -qF "${LTS_START}${section}${MARKER_CLOSE}"
}

replace_lts_section() {
  local content="$1" section="$2" new_body="$3"
  local start_marker="${LTS_START}${section}${MARKER_CLOSE}"
  local end_marker="${LTS_END}${section}${MARKER_CLOSE}"
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

list_lts_sections() {
  local content="$1"
  echo "$content" | grep -oP "(?<=<!-- LTS:start:)[^-][^>]*(?= -->)" || true
}

LTS_SYSTEM_PROMPT='You are a technical writer standardising human-authored README sections.
You will be given the existing content of a section and the current state of the repo.
Your job is to:
  1. Preserve the original intent and any correct information
  2. Fix inaccuracies, outdated references, and missing information
  3. Ensure consistency with the repo'"'"'s current workflows, scripts, and structure
  4. Apply consistent formatting (tables where appropriate, code blocks for commands)
  5. Keep the same general structure unless it is clearly wrong
Output only the updated section content — no headings, no markers, no preamble.'

generate_lts_section() {
  local section="$1" existing_content="$2" context="$3"
  llm_ask "$LTS_SYSTEM_PROMPT" \
    "Section name: ${section}

Existing content:
${existing_content}

Current repo context:
${context}

Standardise this section. Preserve intent, fix inaccuracies, ensure it reflects
the current state of the repo. Output only the updated Markdown content." 3000
}

process_lts_sections() {
  local owner="$1" repo="$2" context="$3" readme_content="$4"

  info "  LTS mode — scanning for LTS:start/end sections..."

  # Find all LTS sections in this README
  local lts_sections
  mapfile -t lts_sections < <(list_lts_sections "$readme_content")

  if [[ "${#lts_sections[@]}" -eq 0 ]]; then
    info "  No LTS sections found — skipping."
    return 0
  fi

  info "  Found ${#lts_sections[@]} LTS section(s): ${lts_sections[*]}"

  local updated_content="$readme_content"
  local changed=false

  for section in "${lts_sections[@]}"; do
    [[ -z "$section" ]] && continue
    info "  Standardising LTS section: ${section}..."

    local existing_body
    existing_body=$(extract_lts_section "$updated_content" "$section")

    local new_body
    new_body=$(generate_lts_section "$section" "$existing_body" "$context")

    if [[ -z "$new_body" ]]; then
      warn "  LLM returned empty for LTS section '${section}' — keeping existing"
      continue
    fi

    # Only update if content actually changed
    if [[ "$existing_body" == "$new_body" ]]; then
      info "  LTS section '${section}' unchanged."
      continue
    fi

    updated_content=$(replace_lts_section "$updated_content" "$section" "$new_body")
    changed=true
    info "  LTS section '${section}' updated."
  done

  if $changed && [[ -n "$updated_content" ]]; then
    local readme_sha new_b64
    readme_sha=$(get_file_sha "$owner" "$repo" "README.md" 2>/dev/null) || readme_sha=""
    new_b64=$(echo "$updated_content" | base64 -w0)
    commit_file "$owner" "$repo" "README.md" \
      "docs: standardise LTS README sections [lts]" \
      "$new_b64" "$readme_sha" \
      && info "  ✅ LTS README committed." \
      || warn "  ❌ Failed to commit LTS README."
  else
    info "  No LTS changes needed."
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

generate_contributors() {
  local owner="$1" repo="$2"
  # Fetch contributor list from GitHub API
  local contributors_json
  contributors_json=$(curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${owner}/${repo}/contributors?per_page=30" 2>/dev/null) || contributors_json="[]"

  # Check for mirrors (OSP/OOC) — link back to upstream
  local is_mirror=false
  if [[ "$owner" == "OpenOS-Project-OSP" || "$owner" == "OpenOS-Project-Ecosystem-OOC" ]]; then
    is_mirror=true
  fi

  local upstream_link=""
  if $is_mirror; then
    upstream_link="Mirrored from [Interested-Deving-1896/${repo}](https://github.com/Interested-Deving-1896/${repo}) — see upstream for full contributor history.\n\n"
  fi

  # Build contributor table from API response
  local table=""
  if echo "$contributors_json" | jq -e '.[0]' > /dev/null 2>&1; then
    table="| Contributor | Commits |\n|---|---|\n"
    while IFS= read -r line; do
      local login contributions
      login=$(echo "$line" | jq -r '.login')
      contributions=$(echo "$line" | jq -r '.contributions')
      table+="| [@${login}](https://github.com/${login}) | ${contributions} |\n"
    done < <(echo "$contributors_json" | jq -c '.[]')
  fi

  local prompt="Write a brief contributors section for ${owner}/${repo}.
${upstream_link}
Contributor data from GitHub API:
${table}

List contributors with their GitHub profile links and commit counts.
If this is a mirror repo, note the upstream source prominently.
Output only the Markdown content — no heading, no markers."

  llm_ask "You are a technical writer. Write concise, factual contributor attribution." \
    "$prompt" 800
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

# ── README mode detection ─────────────────────────────────────────────────────
#
# Three modes:
#   update  — README has AI markers → regenerate AI sections only
#   rewrite — README exists but has NO AI markers → migrate to template,
#             preserving human content that maps to known sections
#   fill    — README has some AI markers but is missing required sections
#             → inject the missing ones

ALL_AI_SECTIONS=("what-it-does" "architecture" "ci" "mirror-chain" "contributors" "origins" "resources" "license")
ALL_HUMAN_SECTIONS=("Install" "Usage" "Configuration" "License")

detect_mode() {
  local content="$1"
  local has_any_marker=false
  local missing_sections=()

  for section in "${ALL_AI_SECTIONS[@]}"; do
    if has_ai_section "$content" "$section"; then
      has_any_marker=true
    else
      missing_sections+=("$section")
    fi
  done

  if ! $has_any_marker; then
    echo "rewrite"
  elif [ "${#missing_sections[@]}" -gt 0 ]; then
    echo "fill"
  else
    echo "update"
  fi
}

# Extract a human-written section from a non-templated README by heading name.
# Returns the content between the heading and the next ## heading (or EOF).
extract_human_section() {
  local content="$1" heading="$2"
  echo "$content" | awk \
    -v h="## ${heading}" \
    'found && /^## /{exit}
     found{print}
     $0 == h{found=1}'
}

# Build a fully templated README from an existing non-templated one,
# preserving any human content that maps to Install/Usage/Configuration/License.
rewrite_readme() {
  local owner="$1" repo="$2" context="$3" old_content="$4"

  info "  Mode: rewrite — migrating to template structure..."

  # Generate AI sections
  local what_it_does architecture ci_section mirror_chain
  what_it_does=$(generate_what_it_does "$context")
  architecture=$(generate_architecture "$context")
  ci_section=$(generate_ci "$context" "$owner" "$repo")
  mirror_chain=$(generate_mirror_chain "$owner" "$repo")
  contributors=$(generate_contributors "$owner" "$repo")
  origins=$(generate_origins "$owner" "$repo")
  resources=$(generate_resources "$owner" "$repo")
  license_body=$(generate_license "$owner" "$repo")

  # Salvage human sections from old README
  local install_content usage_content config_content license_content
  install_content=$(extract_human_section "$old_content" "Install")
  usage_content=$(extract_human_section "$old_content" "Usage")
  config_content=$(extract_human_section "$old_content" "Configuration")
  license_content=$(extract_human_section "$old_content" "License")

  # Fall back to placeholders if nothing was found
  [ -z "$install_content" ] && \
    install_content="<!-- Add installation instructions here. This section is yours — the AI will not modify it. -->

\`\`\`bash
git clone https://github.com/${owner}/${repo}.git
cd ${repo}
\`\`\`"

  [ -z "$usage_content" ] && \
    usage_content="<!-- Add usage examples here. This section is yours — the AI will not modify it. -->"

  [ -z "$config_content" ] && \
    config_content="<!-- Document configuration options here. This section is yours — the AI will not modify it. -->"

  [ -z "$license_content" ] && \
    license_content="<!-- Add license information here. This section is yours — the AI will not modify it. -->"

  cat << EOF
# ${repo}

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/${owner}/${repo})

${AI_START}what-it-does${MARKER_CLOSE}
${what_it_does:-_Description pending._}
${AI_END}what-it-does${MARKER_CLOSE}

## Architecture

${AI_START}architecture${MARKER_CLOSE}
${architecture:-_Architecture documentation pending._}
${AI_END}architecture${MARKER_CLOSE}

## Install

${install_content}

## Usage

${usage_content}

## Configuration

${config_content}

## CI

${AI_START}ci${MARKER_CLOSE}
${ci_section:-_CI documentation pending._}
${AI_END}ci${MARKER_CLOSE}

## Mirror chain

${AI_START}mirror-chain${MARKER_CLOSE}
${mirror_chain}
${AI_END}mirror-chain${MARKER_CLOSE}

## Contributors

${AI_START}contributors${MARKER_CLOSE}
${contributors:-_Contributors pending._}
${AI_END}contributors${MARKER_CLOSE}

## Origins

${AI_START}origins${MARKER_CLOSE}
${origins:-_No dependency graph found._}
${AI_END}origins${MARKER_CLOSE}

## Resources

${AI_START}resources${MARKER_CLOSE}
${resources:-_No additional resources found._}
${AI_END}resources${MARKER_CLOSE}

## License

${AI_START}license${MARKER_CLOSE}
${license_body:-_License not detected._}
${AI_END}license${MARKER_CLOSE}
EOF
}

# Inject any AI sections that are missing from an otherwise-templated README.
fill_missing_sections() {
  local owner="$1" repo="$2" context="$3" content="$4"

  info "  Mode: fill — injecting missing sections..."

  local updated_content="$content"
  local changed=false

  for section in "${ALL_AI_SECTIONS[@]}"; do
    has_ai_section "$updated_content" "$section" && continue

    info "  Injecting missing section: ${section}..."
    local new_body=""
    case "$section" in
      what-it-does)  new_body=$(generate_what_it_does "$context") ;;
      architecture)  new_body=$(generate_architecture "$context") ;;
      ci)            new_body=$(generate_ci "$context" "$owner" "$repo") ;;
      mirror-chain)  new_body=$(generate_mirror_chain "$owner" "$repo") ;;
    esac

    [ -z "$new_body" ] && warn "  LLM empty for '${section}' — skipping" && continue

    # Determine insertion point: after the previous AI section's end marker,
    # or append at end if no anchor found.
    local prev_section=""
    for s in "${ALL_AI_SECTIONS[@]}"; do
      [ "$s" = "$section" ] && break
      has_ai_section "$updated_content" "$s" && prev_section="$s"
    done

    updated_content=$(inject_ai_section "$updated_content" "$section" "$new_body" "$prev_section")
    changed=true
  done

  # Also check human-owned sections — add placeholders if completely absent
  for heading in "${ALL_HUMAN_SECTIONS[@]}"; do
    if ! echo "$updated_content" | grep -q "^## ${heading}"; then
      info "  Adding missing human section placeholder: ${heading}..."
      updated_content="${updated_content}

## ${heading}

<!-- Add ${heading,,} information here. This section is yours — the AI will not modify it. -->"
      changed=true
    fi
  done

  $changed && echo "$updated_content" || echo ""
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

  # Respect opt-out marker — unless FORCE_REWRITE is set, in which case
  # strip it so statically-written READMEs are migrated to the marker template.
  if echo "$readme_content" | grep -q "<!-- AI:skip -->"; then
    if [[ "$FORCE_REWRITE" == "true" ]]; then
      info "  FORCE_REWRITE: stripping <!-- AI:skip --> and migrating to template."
      readme_content=$(echo "$readme_content" | grep -v "<!-- AI:skip -->")
    else
      info "  README has <!-- AI:skip --> marker — skipping."
      return 0
    fi
  fi

  # LTS mode: standardise human-owned LTS sections and return early
  if [[ "$LTS_MODE" == "true" ]]; then
    process_lts_sections "$owner" "$repo" "$context" "$readme_content"
    return 0
  fi

  # Detect which mode to run
  local mode
  mode=$(detect_mode "$readme_content")
  info "  Mode: ${mode}"

  local updated_content=""
  local changed=false

  case "$mode" in
    rewrite)
      updated_content=$(rewrite_readme "$owner" "$repo" "$context" "$readme_content")
      [ -n "$updated_content" ] && changed=true
      ;;

    fill)
      updated_content=$(fill_missing_sections "$owner" "$repo" "$context" "$readme_content")
      [ -n "$updated_content" ] && changed=true
      ;;

    update)
      updated_content="$readme_content"
      # Regenerate each AI-owned section
      for section in "${ALL_AI_SECTIONS[@]}"; do
        info "  Regenerating section: ${section}..."
        local new_body=""
        case "$section" in
          what-it-does)  new_body=$(generate_what_it_does "$context") ;;
          architecture)  new_body=$(generate_architecture "$context") ;;
          ci)            new_body=$(generate_ci "$context" "$owner" "$repo") ;;
          mirror-chain)  new_body=$(generate_mirror_chain "$owner" "$repo") ;;
          contributors)  new_body=$(generate_contributors "$owner" "$repo") ;;
          origins)       new_body=$(generate_origins "$owner" "$repo") ;;
          resources)     new_body=$(generate_resources "$owner" "$repo") ;;
          license)       new_body=$(generate_license "$owner" "$repo") ;;
        esac

        [ -z "$new_body" ] && warn "  LLM empty for '${section}' — keeping existing" && continue

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
      ;;
  esac

  # Inject badge into any existing README that's missing it
  local badged_content
  badged_content=$(inject_badge_if_missing "$updated_content" "$owner" "$repo" "github")
  if [ "$badged_content" != "$updated_content" ]; then
    info "  Badge injected."
    updated_content="$badged_content"
    changed=true
  fi

  if $changed && [ -n "$updated_content" ]; then
    local new_b64
    new_b64=$(echo "$updated_content" | base64 -w0)
    local commit_msg
    case "$mode" in
      rewrite) commit_msg="docs: rewrite README to match extended template [skip ci]" ;;
      fill)    commit_msg="docs: inject missing README sections to meet template [skip ci]" ;;
      update)  commit_msg="docs: update AI-owned README sections [skip ci]" ;;
    esac
    commit_file "$owner" "$repo" "README.md" "$commit_msg" "$new_b64" "$readme_sha" \
      && info "  ✅ README committed (${mode})." \
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

# ── Helpers ──────────────────────────────────────────────────────────────────

# Fetch all repo names from an org, paginated. Exits with code 2 on rate limit.
fetch_org_repos() {
  local org="$1"
  local repos="" page=1
  while true; do
    local response
    response=$(curl -s \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/orgs/${org}/repos?per_page=100&sort=pushed&page=${page}")

    if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
      local msg
      msg=$(echo "$response" | jq -r '.message')
      if echo "$msg" | grep -qi "rate limit"; then
        local reset now reset_in
        reset=$(curl -s \
          -H "Authorization: token ${GH_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "${GH_API}/rate_limit" \
          | jq -r '.resources.core.reset // empty')
        now=$(date +%s)
        reset=${reset:-0}
        reset_in=$(( reset > now ? reset - now : 0 ))
        warn "Rate limited — resets in ${reset_in}s. Re-trigger this workflow after the reset."
        exit 2
      fi
      warn "GitHub API error for org ${org}: ${msg}"
      return 1
    fi

    local page_repos
    page_repos=$(echo "$response" | jq -r '.[].name' 2>/dev/null) || {
      warn "Failed to parse repo list (page ${page}): ${response:0:200}"
      return 1
    }

    [[ -z "$page_repos" ]] && break
    repos="${repos} ${page_repos}"
    local count
    count=$(echo "$page_repos" | wc -l)
    [[ "$count" -lt 100 ]] && break
    (( page++ ))
  done

  echo "$repos" | tr ' ' '\n' | grep -v '^$'
}

# ── Main ─────────────────────────────────────────────────────────────────────

# PRIORITY_ONLY=true  → process only OSP-mirrored repos (fast, low API usage)
# PRIORITY_ONLY=false → process all repos (OSP-mirrored first, then the rest)
PRIORITY_ONLY="${PRIORITY_ONLY:-false}"

# NEW_REPO is set when triggered by Add Mirror Repo — process just that repo.
NEW_REPO="${NEW_REPO:-}"

if [ -n "${CHANGED_REPOS:-}" ]; then
  info "Push trigger mode — processing: ${CHANGED_REPOS}"
  for repo in $CHANGED_REPOS; do
    [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
    process_repo "$GITHUB_OWNER" "$repo"
  done

elif [ -n "${NEW_REPO}" ]; then
  # Triggered by Add Mirror Repo dispatch — process the newly added repo only.
  info "New mirror repo trigger — processing: ${NEW_REPO}"
  process_repo "$GITHUB_OWNER" "$NEW_REPO"

else
  # Fetch priority repos — those mirrored into OSP (highest priority).
  info "Fetching priority repos from OSP mirror..."
  priority_repos=$(fetch_org_repos "OpenOS-Project-OSP") || true
  priority_count=$(echo "$priority_repos" | grep -c '^.' || true)
  info "Found ${priority_count} priority repos (OSP-mirrored)."

  if [[ "$PRIORITY_ONLY" == "true" ]]; then
    info "Priority-only mode — skipping secondary repos."
    for repo in $priority_repos; do
      [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
      process_repo "$GITHUB_OWNER" "$repo"
      sleep 2
    done
  else
    info "Full mode — processing priority repos first, then remaining."

    # Fetch all repos from the owner org.
    all_repos=$(fetch_org_repos "$GITHUB_OWNER")
    if [[ -z "$all_repos" ]]; then
      warn "No repos found in ${GITHUB_OWNER} — check SYNC_TOKEN scopes (needs: repo, read:org)"
      exit 1
    fi
    total=$(echo "$all_repos" | grep -c '^.')
    info "Found ${total} total repos in ${GITHUB_OWNER}."

    # Process priority repos first.
    info "--- Priority pass (OSP-mirrored repos) ---"
    for repo in $priority_repos; do
      [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
      process_repo "$GITHUB_OWNER" "$repo"
      sleep 2
    done

    # Process remaining repos (those not in the priority list).
    info "--- Secondary pass (remaining repos) ---"
    for repo in $all_repos; do
      echo "$priority_repos" | grep -qx "$repo" && continue
      [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
      process_repo "$GITHUB_OWNER" "$repo"
      sleep 2
    done
  fi
fi

echo ""
info "Done."
