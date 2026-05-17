#!/usr/bin/env bash
#
# Translates README.md files across Interested-Deving-1896 repos using the
# GitHub Models API (GPT-4o). Writes translated content to README.<lang>.md
# alongside the original (e.g. README.it.md, README.zh.md).
#
# Translation direction is controlled by SOURCE_LANG and TARGET_LANG:
#   - "en → it"  reads README.md (English) and writes README.it.md
#   - "it → en"  reads README.it.md and writes README.md
#   - "auto → X" detects the source language from the file content
#
# Existing translated files are only updated when the source has changed
# (compared by SHA). Pass FORCE=true to retranslate regardless.
#
# Required env vars:
#   GH_TOKEN      — PAT with repo + models:read scopes
#   GITHUB_OWNER  — org to scan (default: Interested-Deving-1896)
#   SOURCE_LANG   — BCP-47 code or "auto" (default: en)
#   TARGET_LANG   — BCP-47 code (default: it)
#
# Optional env vars:
#   REPOS         — space-separated repo names; empty = all org repos
#   FORCE         — set to "true" to retranslate even if source unchanged
#   DRY_RUN       — set to "true" to print without committing
#   MODEL         — GitHub Models model ID (default: openai/gpt-4o)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
SOURCE_LANG="${SOURCE_LANG:-en}"
TARGET_LANG="${TARGET_LANG:-it}"
SCOPE="${SCOPE:-custom}"
REPOS="${REPOS:-}"
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
MODEL="${MODEL:-openai/gpt-4o}"

# NORMALIZE_TO_EN mode: auto-detect source language on each repo's README.md.
# If already English → skip (no-op). If non-English → translate to English
# (overwrites README.md in place). Activated when SOURCE_LANG=auto and
# TARGET_LANG=en, or explicitly via NORMALIZE_TO_EN=true.
NORMALIZE_TO_EN="${NORMALIZE_TO_EN:-false}"
if [[ "$SOURCE_LANG" == "auto" && "$TARGET_LANG" == "en" ]]; then
  NORMALIZE_TO_EN="true"
fi

# ── Scope expansion ───────────────────────────────────────────────────────────
# Predefined repo groups. When SCOPE is not "custom" or "all", REPOS is
# overridden with the matching list. "all" leaves REPOS empty so get_all_repos
# is used. "custom" passes REPOS through unchanged.

OSP_BOUND="btrfs-dwarfs-framework eggs-ai eggs-gui immutable-linux-framework
  liquorix-unified-kernel liqxanmod lkf lkm oa-tools penguins-eggs
  penguins-eggs-audit penguins-eggs-book penguins-incus-platform
  penguins-kernel-manager penguins-powerwash penguins-recovery ukm
  xanmod-unified-kernel"

PENGUINS_SCOPE="penguins-eggs penguins-eggs-audit penguins-eggs-book
  penguins-eggs-ai penguins-incus-platform penguins-kernel-manager
  penguins-powerwash penguins-recovery"

KERNEL_SCOPE="lkf lkm ukm xanmod-unified-kernel liquorix-unified-kernel liqxanmod"

case "$SCOPE" in
  osp-bound) REPOS="$OSP_BOUND" ;;
  penguins)  REPOS="$PENGUINS_SCOPE" ;;
  kernel)    REPOS="$KERNEL_SCOPE" ;;
  all)       REPOS="" ;;   # empty → get_all_repos() enumerates the org
  custom)    ;;            # REPOS passed through as-is from workflow input
  *)         warn "Unknown scope '${SCOPE}' — falling back to custom"; ;;
esac

GH_API="https://api.github.com"
MODELS_API="https://models.github.ai/inference"
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

info() { echo "[translate-readmes] $*"; }
warn() { echo "[warn] $*" >&2; }
dry()  { echo "[dry-run] $*"; }

# ── Language metadata ─────────────────────────────────────────────────────────
# Maps BCP-47 codes to human-readable names for prompts and file naming.

lang_name() {
  case "$1" in
    en)    echo "English" ;;
    it)    echo "Italian" ;;
    es)    echo "Spanish" ;;
    fr)    echo "French" ;;
    de)    echo "German" ;;
    pt)    echo "Portuguese" ;;
    zh)    echo "Chinese (Simplified)" ;;
    zh-tw) echo "Chinese (Traditional)" ;;
    ja)    echo "Japanese" ;;
    ko)    echo "Korean" ;;
    ru)    echo "Russian" ;;
    ar)    echo "Arabic" ;;
    hi)    echo "Hindi" ;;
    nl)    echo "Dutch" ;;
    pl)    echo "Polish" ;;
    tr)    echo "Turkish" ;;
    sv)    echo "Swedish" ;;
    uk)    echo "Ukrainian" ;;
    *)     echo "$1" ;;
  esac
}

# Returns the README filename for a given language code.
# English is always README.md; others are README.<code>.md.
readme_filename() {
  local lang="$1"
  if [[ "$lang" == "en" ]]; then
    echo "README.md"
  else
    echo "README.${lang}.md"
  fi
}

# ── GitHub API helpers ────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"; shift 2
  local attempt=0 max_retries=3
  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$HEADER_FILE" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      [[ $attempt -gt $max_retries ]] && { echo "$body"; return 1; }
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      [[ "$wait" -gt 0 && "$wait" -lt 3700 ]] && sleep "$wait" || sleep 60
      continue
    fi
    echo "$body"; return 0
  done
}

# Fetch file content (decoded) and SHA for a repo path.
# Outputs "sha|decoded_content" or returns 1 if not found.
get_file() {
  local repo="$1" path="$2"
  local info sha content
  info=$(gh_api GET "${GH_API}/repos/${GITHUB_OWNER}/${repo}/contents/${path}" 2>/dev/null) || return 1
  sha=$(echo "$info" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null) || return 1
  content=$(echo "$info" | python3 -c \
    "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d.get('content','')).decode('utf-8','replace'))" \
    2>/dev/null) || return 1
  [[ -z "$sha" ]] && return 1
  printf '%s|%s' "$sha" "$content"
}

# Commit a file to a repo. Creates or updates.
commit_file() {
  local repo="$1" path="$2" message="$3" content="$4" existing_sha="$5"
  local content_b64
  content_b64=$(printf '%s' "$content" | base64 | tr -d '\n')
  local payload
  if [[ -n "$existing_sha" ]]; then
    payload=$(python3 -c "
import json, sys
print(json.dumps({'message': sys.argv[1], 'content': sys.argv[2], 'sha': sys.argv[3]}))
" "$message" "$content_b64" "$existing_sha")
  else
    payload=$(python3 -c "
import json, sys
print(json.dumps({'message': sys.argv[1], 'content': sys.argv[2]}))
" "$message" "$content_b64")
  fi
  gh_api PUT "${GH_API}/repos/${GITHUB_OWNER}/${repo}/contents/${path}" \
    -H "Content-Type: application/json" --data "$payload" > /dev/null
}

# ── LLM translation ───────────────────────────────────────────────────────────

llm_translate() {
  local source_text="$1" source_lang_name="$2" target_lang_name="$3"
  local tmp_in tmp_out
  tmp_in=$(mktemp)
  tmp_out=$(mktemp)
  trap 'rm -f "$tmp_in" "$tmp_out"' RETURN

  printf '%s' "$source_text" > "$tmp_in"

  local attempt=0 max_retries=3
  while true; do
    local payload response http_code body

    payload=$(SOURCE_LANG_NAME="$source_lang_name" \
              TARGET_LANG_NAME="$target_lang_name" \
              MODEL="$MODEL" \
              python3 - "$tmp_in" << 'PYEOF'
import json, os, sys

src_lang = os.environ['SOURCE_LANG_NAME']
tgt_lang = os.environ['TARGET_LANG_NAME']
model    = os.environ['MODEL']
text     = open(sys.argv[1]).read()

system = (
    f"You are a technical translator. Translate the following Markdown README "
    f"from {src_lang} to {tgt_lang}. Rules:\n"
    "- Preserve all Markdown formatting exactly (headings, code blocks, tables, links, badges).\n"
    "- Do NOT translate: code blocks, inline code, URLs, file paths, command names, "
    "variable names, repo names, org names, or badge alt text.\n"
    "- Translate only prose text, section headings, and table cell content that is natural language.\n"
    "- Keep the same document structure and section order.\n"
    "- Output only the translated Markdown, no preamble or explanation."
)

print(json.dumps({
    'model': model,
    'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user',   'content': text},
    ],
    'temperature': 0.1,
    'max_tokens': 8000,
}))
PYEOF
)

    response=$(curl -s -w "\n%{http_code}" \
      -X POST "${MODELS_API}/chat/completions" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
      echo "$body" | python3 -c \
        "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" \
        2>/dev/null
      return 0
    elif [[ "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      [[ $attempt -gt $max_retries ]] && { warn "LLM rate limit exceeded after ${max_retries} retries"; return 1; }
      local retry_after
      retry_after=$(echo "$body" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('retry_after', 60))" 2>/dev/null || echo 60)
      warn "LLM rate limited — sleeping ${retry_after}s (attempt ${attempt}/${max_retries})"
      sleep "$retry_after"
      continue
    else
      warn "LLM call failed (HTTP ${http_code}): $(echo "$body" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message', d))" 2>/dev/null || echo "$body")"
      return 1
    fi
  done
}

# Detect the primary language of a text using the LLM.
detect_language() {
  local text="$1"
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  printf '%s' "$text" | head -c 2000 > "$tmp"  # first 2000 chars is enough

  local payload response http_code body
  payload=$(MODEL="$MODEL" python3 - "$tmp" << 'PYEOF'
import json, os, sys
model = os.environ['MODEL']
text  = open(sys.argv[1]).read()
print(json.dumps({
    'model': model,
    'messages': [
        {'role': 'system', 'content':
            'Identify the primary human language of the following text. '
            'Reply with only the BCP-47 language code (e.g. "en", "it", "es", "fr", "de", "zh"). '
            'No explanation.'},
        {'role': 'user', 'content': text},
    ],
    'temperature': 0,
    'max_tokens': 10,
}))
PYEOF
)
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${MODELS_API}/chat/completions" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    echo "$body" | python3 -c \
      "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip().lower())" \
      2>/dev/null || echo "en"
  else
    echo "en"
  fi
}

# ── Repo enumeration ──────────────────────────────────────────────────────────

get_all_repos() {
  local page=1
  while true; do
    local result count
    result=$(gh_api GET "${GH_API}/users/${GITHUB_OWNER}/repos?per_page=100&page=${page}") || break
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null) || break
    [[ -z "$count" || "$count" == "0" ]] && break
    echo "$result" | python3 -c "import json,sys; [print(r['name']) for r in json.load(sys.stdin)]" 2>/dev/null
    (( page++ ))
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

[[ "$DRY_RUN" == "true" ]] && info "DRY RUN — no commits will be made"

src_name=$(lang_name "$SOURCE_LANG")
tgt_name=$(lang_name "$TARGET_LANG")
src_file=$(readme_filename "$SOURCE_LANG")
tgt_file=$(readme_filename "$TARGET_LANG")

info "Translation: ${src_name} (${src_file}) → ${tgt_name} (${tgt_file})"
info "Model: ${MODEL}"
echo ""

# Build repo list
if [[ -n "$REPOS" ]]; then
  mapfile -t repo_list <<< "$(echo "$REPOS" | tr ' ' '\n' | grep -v '^$')"
else
  mapfile -t repo_list <<< "$(get_all_repos)"
fi

info "Repos to process: ${#repo_list[@]}"
echo ""

translated=0
skipped=0
failed=0
no_source=0

for repo in "${repo_list[@]}"; do
  [[ -z "$repo" ]] && continue
  info "── ${repo}"

  # Resolve actual source file when SOURCE_LANG is "auto"
  actual_src_file="$src_file"
  actual_src_lang="$SOURCE_LANG"
  actual_src_name="$src_name"

  if [[ "$NORMALIZE_TO_EN" == "true" ]]; then
    # Auto-detect language of README.md; skip if already English, translate
    # in-place (overwrite README.md) if non-English.
    src_info=$(get_file "$repo" "README.md" 2>/dev/null) || src_info=""
    if [[ -z "$src_info" ]]; then
      info "  No README.md found — skipping"
      (( no_source++ )) || true
      continue
    fi
    src_sha="${src_info%%|*}"
    src_text="${src_info#*|}"
    actual_src_lang=$(detect_language "$src_text")
    actual_src_name=$(lang_name "$actual_src_lang")
    actual_src_file="README.md"
    info "  Detected source language: ${actual_src_name} (${actual_src_lang})"

    if [[ "$actual_src_lang" == "en" ]]; then
      info "  Already English — skipping"
      (( skipped++ )) || true
      continue
    fi

    # Non-English: translate to English and overwrite README.md
    actual_tgt_file="README.md"
    actual_tgt_lang="en"
    actual_tgt_name="English"
    info "  Translating ${actual_src_name} → English (overwriting README.md)..."

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "  Would translate ${repo}/README.md (${actual_src_name}) → English in place"
      (( translated++ )) || true
      continue
    fi

    translated_text=$(llm_translate "$src_text" "$actual_src_name" "English") || {
      warn "  Translation failed for ${repo} — skipping"
      (( failed++ )) || true
      continue
    }

    # No SHA watermark when overwriting the canonical README.md
    if commit_file "$repo" "README.md" \
        "docs: translate README from ${actual_src_name} to English [auto]" \
        "$translated_text" "$src_sha"; then
      info "  ✓ committed README.md (now English)"
      (( translated++ )) || true
    else
      warn "  ✗ commit failed for ${repo}/README.md"
      (( failed++ )) || true
    fi
    continue

  elif [[ "$SOURCE_LANG" == "auto" ]]; then
    # Generic auto-detect (non-normalize mode)
    src_info=$(get_file "$repo" "README.md" 2>/dev/null) || src_info=""
    if [[ -z "$src_info" ]]; then
      info "  No README.md found — skipping"
      (( no_source++ )) || true
      continue
    fi
    src_sha="${src_info%%|*}"
    src_text="${src_info#*|}"
    actual_src_lang=$(detect_language "$src_text")
    actual_src_name=$(lang_name "$actual_src_lang")
    actual_src_file="README.md"
    info "  Detected source language: ${actual_src_name} (${actual_src_lang})"
  else
    src_info=$(get_file "$repo" "$actual_src_file" 2>/dev/null) || src_info=""
    if [[ -z "$src_info" ]]; then
      info "  No ${actual_src_file} found — skipping"
      (( no_source++ )) || true
      continue
    fi
    src_sha="${src_info%%|*}"
    src_text="${src_info#*|}"
  fi

  # Skip if source and target language are the same
  if [[ "$actual_src_lang" == "$TARGET_LANG" ]]; then
    info "  Source and target language are the same (${TARGET_LANG}) — skipping"
    (( skipped++ )) || true
    continue
  fi

  # Check if target already exists and whether source has changed
  tgt_info=$(get_file "$repo" "$tgt_file" 2>/dev/null) || tgt_info=""
  tgt_sha=""
  if [[ -n "$tgt_info" ]]; then
    tgt_sha="${tgt_info%%|*}"
    if [[ "$FORCE" != "true" ]]; then
      # Compare source SHA stored in a comment at the top of the translated file
      tgt_text="${tgt_info#*|}"
      stored_src_sha=$(echo "$tgt_text" | grep -oP '(?<=<!-- translated-from-sha: )[a-f0-9]+(?= -->)' | head -1 || true)
      if [[ "$stored_src_sha" == "$src_sha" ]]; then
        info "  ${tgt_file} is up to date (source SHA unchanged) — skipping"
        (( skipped++ )) || true
        continue
      fi
    fi
  fi

  info "  Translating ${actual_src_file} → ${tgt_file} ..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "  Would translate ${repo}/${actual_src_file} (${actual_src_name}) → ${tgt_file} (${tgt_name})"
    (( translated++ )) || true
    continue
  fi

  translated_text=$(llm_translate "$src_text" "$actual_src_name" "$tgt_name") || {
    warn "  Translation failed for ${repo} — skipping"
    (( failed++ )) || true
    continue
  }

  # Prepend a SHA watermark so future runs can detect staleness
  final_content="<!-- translated-from-sha: ${src_sha} -->
<!-- This file was automatically translated from ${actual_src_file} by translate-readmes.sh -->
<!-- Do not edit manually — changes will be overwritten on the next translation run -->

${translated_text}"

  commit_msg="docs: translate README to ${tgt_name} [auto]"
  if commit_file "$repo" "$tgt_file" "$commit_msg" "$final_content" "$tgt_sha"; then
    info "  ✓ committed ${tgt_file}"
    (( translated++ )) || true
  else
    warn "  ✗ commit failed for ${repo}/${tgt_file}"
    (( failed++ )) || true
  fi
done

echo ""
echo "════════════════════════════════════════════"
echo "  translate-readmes complete"
echo "  Translated  : ${translated}"
echo "  Skipped     : ${skipped}  (up to date or same language)"
echo "  No source   : ${no_source}"
echo "  Failed      : ${failed}"
echo "════════════════════════════════════════════"

[[ "$failed" -gt 0 ]] && exit 1
exit 0
