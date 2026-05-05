#!/usr/bin/env bash
#
# Creates README.md files for repos that don't have one, using an AI-generated
# extended template with section markers for AI-owned sections.
#
# Template sections:
#   ## What it does        <!-- AI:start:what-it-does --> ... <!-- AI:end:what-it-does -->
#   ## Architecture        <!-- AI:start:architecture --> ... <!-- AI:end:architecture -->
#   ## Install             (human-owned — placeholder text, no markers)
#   ## Usage               (human-owned — placeholder text, no markers)
#   ## Configuration       (human-owned — placeholder text, no markers)
#   ## CI                  <!-- AI:start:ci --> ... <!-- AI:end:ci -->
#   ## Mirror chain        <!-- AI:start:mirror-chain --> ... <!-- AI:end:mirror-chain -->
#   ## License             (human-owned — placeholder)
#
# Human-owned sections get placeholder text on first creation. Remove the
# placeholder and add your own content — the AI will never overwrite sections
# that lack AI markers.
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with repo + models:read scopes
#   GITHUB_OWNER  — org to scan (Interested-Deving-1896)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

GH_API="https://api.github.com"
MODELS_API="https://models.github.ai/inference"
MODEL="openai/gpt-4o"

AI_START="<!-- AI:start:"
AI_END="<!-- AI:end:"
MARKER_CLOSE=" -->"

info() { echo "[create-readmes] $*"; }
warn() { echo "[warn] $*" >&2; }

# ── LLM (same as update-readmes.sh) ──────────────────────────────────────────

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

readme_exists() {
  local owner="$1" repo="$2"
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    "${GH_API}/repos/${owner}/${repo}/contents/README.md" 2>/dev/null) || true
  [ "$status" = "200" ]
}

commit_file() {
  local owner="$1" repo="$2" path="$3" message="$4" content_b64="$5"
  local payload
  payload=$(jq -n --arg m "$message" --arg c "$content_b64" '{message:$m,content:$c}')
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${owner}/${repo}/contents/${path}" \
    -d "$payload" > /dev/null
}

collect_repo_context() {
  local owner="$1" repo="$2"
  local context=""

  local meta
  meta=$(gh_get "${GH_API}/repos/${owner}/${repo}" 2>/dev/null) || return 1
  local description language
  description=$(echo "$meta" | jq -r '.description // ""')
  language=$(echo "$meta" | jq -r '.language // ""')
  context+="Repository: ${owner}/${repo}\n"
  context+="Description: ${description}\n"
  context+="Primary language: ${language}\n\n"

  local sample_files=(
    "package.json" "Cargo.toml" "go.mod" "pyproject.toml" "setup.py"
    "Makefile" "CMakeLists.txt"
  )
  for f in "${sample_files[@]}"; do
    local content
    content=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      "${GH_API}/repos/${owner}/${repo}/contents/${f}" 2>/dev/null \
      | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null | head -c 1500) || continue
    [ -z "$content" ] && continue
    context+="=== ${f} ===\n${content}\n\n"
  done

  local workflows
  workflows=$(gh_get "${GH_API}/repos/${owner}/${repo}/contents/.github/workflows" 2>/dev/null \
    | jq -r '.[].name' 2>/dev/null | tr '\n' ' ') || true
  [ -n "$workflows" ] && context+="Workflows: ${workflows}\n\n"

  local tree
  tree=$(gh_get "${GH_API}/repos/${owner}/${repo}/git/trees/HEAD" 2>/dev/null \
    | jq -r '.tree[].path' 2>/dev/null | head -30 | tr '\n' ' ') || true
  [ -n "$tree" ] && context+="Top-level files: ${tree}\n\n"

  echo -e "$context"
}

# ── README builder ────────────────────────────────────────────────────────────

SYSTEM_PROMPT='You are a technical writer for an open-source infrastructure project.
Write concise, factual README sections in Markdown. No marketing language.
No superlatives. No filler. Output only the requested section content —
no headings, no markers, no preamble. Use present tense.'

ai_section() {
  local name="$1" body="$2"
  printf '%s%s%s\n%s\n%s%s%s' \
    "$AI_START" "$name" "$MARKER_CLOSE" \
    "$body" \
    "$AI_END" "$name" "$MARKER_CLOSE"
}

build_readme() {
  local owner="$1" repo="$2" context="$3"

  info "  Generating sections..."

  local what_it_does architecture ci_section mirror_chain
  local desc_oneliner topics_raw

  what_it_does=$(llm_ask "$SYSTEM_PROMPT" \
    "Write a 2-4 sentence description of what this project does. Focus on the problem it solves.
No bullet points.\n\n${context}" 500)

  architecture=$(llm_ask "$SYSTEM_PROMPT" \
    "Write an Architecture section. Describe key components and how they interact.
Use a short paragraph and/or a directory tree code block. Under 20 lines.\n\n${context}" 800)

  ci_section=$(llm_ask "$SYSTEM_PROMPT" \
    "Write a CI section listing the GitHub Actions workflows, what each does, and required secrets.
Under 15 lines.\n\n${context}" 600)

  mirror_chain="This repo is maintained in [\`${owner}/${repo}\`](https://github.com/${owner}/${repo}) and mirrored through:

\`\`\`
${owner}/${repo}  ──►  OpenOS-Project-OSP/${repo}  ──►  OpenOS-Project-Ecosystem-OOC/${repo}
\`\`\`

Changes flow downstream automatically via the hourly mirror chain in
[\`fork-sync-all\`](https://github.com/${owner}/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to \`${owner}\`."

  desc_oneliner=$(llm_ask "$SYSTEM_PROMPT" \
    "Write a single sentence (max 120 chars) for the GitHub repo description. No punctuation at end.\n\n${context}" 80)

  topics_raw=$(llm_ask "$SYSTEM_PROMPT" \
    "List 5-8 GitHub topic tags as a JSON array of lowercase hyphenated strings. Output only the JSON array.\n\n${context}" 80)

  # Update repo metadata
  if [ -n "$desc_oneliner" ]; then
    gh_patch "${GH_API}/repos/${owner}/${repo}" \
      -d "{\"description\":$(echo "$desc_oneliner" | jq -Rs .)}" > /dev/null \
      && info "  Description set." || warn "  Failed to set description."
  fi
  if echo "$topics_raw" | jq -e 'if type=="array" then . else error end' > /dev/null 2>&1; then
    curl -sf -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "${GH_API}/repos/${owner}/${repo}/topics" \
      -d "{\"names\":${topics_raw}}" > /dev/null \
      && info "  Topics set." || warn "  Failed to set topics."
  fi

  # Assemble full README
  cat << EOF
# ${repo}

$(ai_section "what-it-does" "${what_it_does:-_Description pending._}")

## Architecture

$(ai_section "architecture" "${architecture:-_Architecture documentation pending._}")

## Install

<!-- Add installation instructions here. This section is yours — the AI will not modify it. -->

\`\`\`bash
# Example
git clone https://github.com/${owner}/${repo}.git
cd ${repo}
\`\`\`

## Usage

<!-- Add usage examples here. This section is yours — the AI will not modify it. -->

## Configuration

<!-- Document configuration options here. This section is yours — the AI will not modify it. -->

## CI

$(ai_section "ci" "${ci_section:-_CI documentation pending._}")

## Mirror chain

$(ai_section "mirror-chain" "${mirror_chain}")

## License

<!-- Add license information here. This section is yours — the AI will not modify it. -->
EOF
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "========================================"
echo "  README Creator"
echo "  Owner: ${GITHUB_OWNER}"
echo "========================================"
echo ""

repos=$(gh_get "${GH_API}/orgs/${GITHUB_OWNER}/repos?per_page=100&sort=pushed" \
  | jq -r '.[].name' 2>/dev/null) || { warn "Failed to list repos"; exit 1; }

created=0
skipped=0

for repo in $repos; do
  if readme_exists "$GITHUB_OWNER" "$repo"; then
    (( skipped++ )) || true
    continue
  fi

  info "──────────────────────────────────────────"
  info "${GITHUB_OWNER}/${repo} — no README found, creating..."

  context=$(collect_repo_context "$GITHUB_OWNER" "$repo") || {
    warn "  Could not collect context — skipping"
    continue
  }

  readme=$(build_readme "$GITHUB_OWNER" "$repo" "$context")

  if [ -z "$readme" ]; then
    warn "  README generation failed — skipping"
    continue
  fi

  readme_b64=$(echo "$readme" | base64 -w0)
  if commit_file "$GITHUB_OWNER" "$repo" "README.md" \
      "docs: create initial README with AI-generated sections [skip ci]" \
      "$readme_b64"; then
    info "  ✅ README created."
    (( created++ )) || true
  else
    warn "  ❌ Failed to commit README."
  fi

  sleep 3  # Avoid GitHub Models rate limits
done

echo ""
info "Complete — created: ${created} | skipped (already have README): ${skipped}"
