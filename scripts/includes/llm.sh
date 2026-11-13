#!/usr/bin/env bash
# scripts/includes/llm.sh
#
# Shared LLM translation helpers for translate-readmes.sh and translate-docs.sh.
# Source this file after setting LLM_BASE_URL, LLM_API_KEY, and MODEL.
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
#   LLM_BASE_URL — OpenAI-compatible API base URL (required; no implicit provider)
#   LLM_API_KEY  — provider API key (required; never fall back to GitHub tokens)
#   MODEL        — model ID expected by the configured provider (required in production)

# Guard against double-sourcing
[[ -n "${_LLM_SH_LOADED:-}" ]] && return 0
_LLM_SH_LOADED=1

MODEL="${MODEL:-}"
LLM_BASE_URL="${LLM_BASE_URL:-}"
LLM_API_KEY="${LLM_API_KEY:-}"

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

  if [[ -z "$LLM_BASE_URL" || -z "$LLM_API_KEY" || -z "$MODEL" ]]; then
    echo "[llm.sh] LLM is not configured: set LLM_BASE_URL, LLM_API_KEY, and MODEL" >&2
    return 1
  fi
  if [[ ! "$LLM_BASE_URL" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "[llm.sh] LLM_BASE_URL must be an HTTP(S) URL" >&2
    return 1
  fi

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
      -H "Authorization: Bearer ${LLM_API_KEY}" \
      -H "Content-Type: application/json" \
      "${LLM_BASE_URL%/}/chat/completions" \
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
      # Never print the provider response body: it may echo request content or
      # contain provider-specific details. The status code is safe and useful.
      echo "[llm.sh] LLM call failed: HTTP ${http_code} (response body suppressed)" >&2
      return 1
    fi

    # Extract content from response. Keep diagnostics useful but never dump
    # the full response body, which may contain provider details.
    local content
    content=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("[llm.sh] HTTP 200 response was not valid JSON", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[llm.sh] HTTP 200 response had unexpected JSON type: {type(data).__name__}", file=sys.stderr)
    sys.exit(3)

choices = data.get("choices")
if not isinstance(choices, list) or not choices:
    keys = ", ".join(sorted(str(k) for k in data.keys())[:12])
    print(f"[llm.sh] HTTP 200 response contained no choices (response shape: {keys})", file=sys.stderr)
    sys.exit(3)

choice = choices[0] if isinstance(choices[0], dict) else {}
message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
text = message.get("content")
if not isinstance(text, str) or not text.strip():
    finish = choice.get("finish_reason", "unknown")
    print(f"[llm.sh] HTTP 200 response had no text content (finish_reason: {finish})", file=sys.stderr)
    sys.exit(4)

print(text)
') || return 1

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
