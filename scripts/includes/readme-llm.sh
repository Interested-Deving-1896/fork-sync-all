#!/usr/bin/env bash
# Shared bounded Retry-After handling for the README updater's GitHub Models calls.
# Expects MODEL, MODELS_API, GH_TOKEN, and warn() to be defined by the caller.

llm_ask() {
  local system_prompt="$1" user_prompt="$2" max_tokens="${3:-2000}"
  local payload
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg sys "$system_prompt" \
    --arg usr "$user_prompt" \
    --argjson mt "$max_tokens" \
    '{model:$model,messages:[{role:"system",content:$sys},{role:"user",content:$usr}],temperature:0.2,max_tokens:$mt}') || {
      warn "Could not build GitHub Models request payload"
      echo ""
      return 0
    }

  local max_retries=3 attempt=0 response http_code body curl_status
  local headers
  headers=$(mktemp) || {
    warn "Could not create temporary headers file for GitHub Models request"
    echo ""
    return 0
  }

  while (( attempt <= max_retries )); do
    : > "$headers"
    curl_status=0
    response=$(curl -sS -w "\n%{http_code}" \
      -D "$headers" \
      -X POST "${MODELS_API}/chat/completions" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null) || curl_status=$?

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "429" ]]; then
      if (( attempt >= max_retries )); then
        warn "GitHub Models rate limit persisted after ${max_retries} retries"
        rm -f "$headers"
        echo ""
        return 0
      fi

      ((attempt++))
      local retry_after wait_seconds
      retry_after=$(awk 'BEGIN { IGNORECASE=1 } /^Retry-After:[[:space:]]*/ { gsub("\\r", "", $2); value=$2 } END { print value }' "$headers" 2>/dev/null)
      if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        wait_seconds="$retry_after"
      else
        wait_seconds=60
      fi
      # Keep a malformed or unexpectedly long server hint from stalling the
      # scheduled updater indefinitely. Retry budget remains three retries.
      if (( wait_seconds > 900 )); then
        warn "Retry-After ${wait_seconds}s exceeds the 900s cap; capping wait"
        wait_seconds=900
      fi
      warn "GitHub Models rate limited (HTTP 429); waiting ${wait_seconds}s (retry ${attempt}/${max_retries})"
      sleep "$wait_seconds"
      continue
    fi

    rm -f "$headers"
    if (( curl_status != 0 )) || [[ ! "$http_code" =~ ^[0-9]{3}$ || "$http_code" != "200" ]]; then
      warn "LLM call failed (HTTP ${http_code:-unknown}; response body suppressed)"
      echo ""
      return 0
    fi

    local content
    content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || content=""
    if [[ -z "${content//[[:space:]]/}" ]]; then
      warn "LLM returned empty content (HTTP 200)"
      echo ""
      return 0
    fi
    printf '%s\n' "$content"
    return 0
  done

  rm -f "$headers"
  warn "LLM call failed after bounded retries"
  echo ""
}
