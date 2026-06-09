#!/usr/bin/env bash
# scripts/includes/llm.sh
#
# Shared LLM translation helpers for translate-readmes.sh and translate-docs.sh.
# Source this file after setting GH_TOKEN and MODEL.
#
# Provides:
#   lang_name CODE          — BCP-47 code → human-readable name
#   build_switcher LANG     — language switcher bar (README variant)
#   readme_filename LANG    — README.<lang>.md or README.md for English
#   detect_language TEXT    — returns BCP-47 code via LLM
#   llm_translate TEXT SRC_NAME TGT_NAME — returns translated markdown
#   llm_call SYSTEM USER    — raw LLM call, returns response text
#
# Required env vars (must be set before sourcing):
#   GH_TOKEN   — PAT with models:read scope
#   MODEL      — GitHub Models model ID (default: openai/gpt-4o)

# Guard against double-sourcing
[[ -n "${_LLM_SH_LOADED:-}" ]] && return 0
_LLM_SH_LOADED=1

MODEL="${MODEL:-openai/gpt-4o}"
_LLM_MODELS_API="https://models.github.ai/inference"

# ── Language metadata ─────────────────────────────────────────────────────────

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

# Builds the language switcher bar for README files.
# The current language is shown as plain text; all others are links.
build_switcher() {
  local current="$1"
  local -A labels=(
    [en]="🇬🇧 English"   [de]="🇩🇪 Deutsch"    [es]="🇪🇸 Español"
    [fr]="🇫🇷 Français"  [it]="🇮🇹 Italiano"   [nl]="🇳🇱 Nederlands"
    [pl]="🇵🇱 Polski"    [pt]="🇵🇹 Português"  [sv]="🇸🇪 Svenska"
    [tr]="🇹🇷 Türkçe"    [uk]="🇺🇦 Українська" [ru]="🇷🇺 Русский"
    [ar]="🇸🇦 العربية"   [hi]="🇮🇳 हिन्दी"      [ja]="🇯🇵 日本語"
    [ko]="🇰🇷 한국어"     [zh]="🇨🇳 中文"        [zh-tw]="🇹🇼 繁體中文"
  )
  local order=(en de es fr it nl pl pt sv tr uk ru ar hi ja ko zh zh-tw)
  local parts=()
  for lang in "${order[@]}"; do
    local label="${labels[$lang]}"
    local file
    file=$(readme_filename "$lang")
    if [[ "$lang" == "$current" ]]; then
      parts+=("$label")
    else
      parts+=("[${label}](${file})")
    fi
  done
  local IFS=" • "
  echo "${parts[*]}"
}

# ── Raw LLM call ──────────────────────────────────────────────────────────────
# llm_call SYSTEM_PROMPT USER_PROMPT
# Prints the model's response text to stdout. Returns 1 on failure.
# Retries up to 3 times on rate-limit (429) or server error (5xx).

llm_call() {
  local system_prompt="$1"
  local user_prompt="$2"
  local attempt=0 max_retries=3

  while (( attempt <= max_retries )); do
    local payload response http_code body
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [
        {'role': 'system', 'content': sys.argv[2]},
        {'role': 'user',   'content': sys.argv[3]}
    ],
    'temperature': 0.3,
    'max_tokens': 8192
}))
" "$MODEL" "$system_prompt" "$user_prompt" 2>/dev/null) || return 1

    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${_LLM_MODELS_API}/chat/completions" \
      -d "$payload" 2>/dev/null) || { (( attempt++ )); sleep 5; continue; }

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "429" || "$http_code" == "503" || "$http_code" == "502" ]]; then
      (( attempt++ )) || true
      local wait=$(( attempt * 30 ))
      echo "[llm.sh] Rate limited (${http_code}) — waiting ${wait}s (attempt ${attempt}/${max_retries})" >&2
      sleep "$wait"
      continue
    fi

    if [[ "$http_code" != "200" ]]; then
      echo "[llm.sh] LLM call failed: HTTP ${http_code}" >&2
      echo "[llm.sh] Response: ${body}" >&2
      return 1
    fi

    # Extract content from response
    local content
    content=$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
choices = d.get('choices', [])
if not choices:
    sys.exit(1)
print(choices[0].get('message', {}).get('content', ''))
" 2>/dev/null) || return 1

    echo "$content"
    return 0
  done

  echo "[llm.sh] LLM call failed after ${max_retries} retries" >&2
  return 1
}

# ── Language detection ────────────────────────────────────────────────────────
# detect_language TEXT
# Returns a BCP-47 language code (e.g. "en", "it", "fr").
# Uses the first 500 chars of text to keep token usage low.

detect_language() {
  local text="${1:0:500}"
  local result

  result=$(llm_call \
    "You are a language detection tool. Respond with only a BCP-47 language code (e.g. en, it, fr, de, es, pt, zh, ja, ko, ru, ar, hi, nl, pl, tr, sv, uk). No explanation, no punctuation." \
    "Detect the language of this text: ${text}" 2>/dev/null) || echo "en"

  # Sanitise — strip whitespace, lowercase, keep only valid BCP-47 chars
  echo "$result" | tr '[:upper:]' '[:lower:]' | tr -d ' \n\r' | grep -oE '^[a-z]{2}(-[a-z]{2,4})?$' || echo "en"
}

# ── Translation ───────────────────────────────────────────────────────────────
# llm_translate TEXT SRC_LANG_NAME TGT_LANG_NAME
# Translates markdown TEXT from SRC_LANG_NAME to TGT_LANG_NAME.
# Preserves all markdown formatting, code blocks, links, and HTML comments.
# Returns translated text on stdout. Returns 1 on failure.

llm_translate() {
  local text="$1"
  local src_name="$2"
  local tgt_name="$3"

  local system_prompt="You are a professional technical translator specialising in software documentation. \
Translate the following ${src_name} markdown document to ${tgt_name}. \
Rules: \
1. Preserve all markdown formatting exactly (headings, bold, italic, lists, tables, code blocks, links). \
2. Do NOT translate content inside backtick code blocks, inline code, URLs, or HTML tags. \
3. Do NOT translate proper nouns: repository names, organisation names, tool names, command names, file paths, environment variable names. \
4. Preserve all HTML comments (<!-- ... -->) exactly as-is. \
5. Output only the translated markdown — no preamble, no explanation, no code fences wrapping the output."

  llm_call "$system_prompt" "$text"
}
