#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "$LLM_TEST_STATE" ]] && count="$(cat "$LLM_TEST_STATE")"
count=$((count + 1))
printf '%s' "$count" >"$LLM_TEST_STATE"
if [[ "$LLM_TEST_MODE" == "recover" && "$count" -eq 1 ]]; then
  printf 'gateway temporarily returned non-json\n200'
elif [[ "$LLM_TEST_MODE" == "always-invalid" ]]; then
  printf 'not-json\n200'
else
  printf '{"choices":[{"message":{"content":"ciao"}}]}\n200'
fi
MOCK_CURL
cat >"$tmp/bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"
PATH="$tmp/bin:$PATH"
export PATH
export GH_TOKEN="test-token" MODEL="test/model" LLM_TEST_STATE="$tmp/count"

source "$repo_root/scripts/includes/llm.sh"

export LLM_TEST_MODE="recover"
result="$(llm_call "system" "user")"
[[ "$result" == "ciao" ]]
[[ "$(cat "$LLM_TEST_STATE")" == "2" ]]

printf '0' >"$LLM_TEST_STATE"
export LLM_TEST_MODE="always-invalid"
if llm_call "system" "user" >/dev/null 2>&1; then
  echo "expected invalid responses to fail after bounded retries" >&2
  exit 1
fi
[[ "$(cat "$LLM_TEST_STATE")" == "4" ]]

echo "llm invalid HTTP 200 response retry: ok"
