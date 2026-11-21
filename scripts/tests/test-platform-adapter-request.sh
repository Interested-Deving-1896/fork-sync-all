#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/scripts/includes/platform-adapter.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
export CURL_CALL_LOG="${tmp_dir}/curl.log"

cat >"${tmp_dir}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_CALL_LOG"
header_file=""
while (($#)); do
  case "$1" in
    -D) header_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$header_file" ]] && printf 'HTTP/1.1 200 OK\r\n' >"$header_file"
printf '{"ok":true}\n'
printf '\n200'
MOCK_CURL
chmod +x "${tmp_dir}/curl"
PATH="${tmp_dir}:$PATH"

PLATFORM_TOKEN="test-token"
pa_init gitlab >/dev/null

response=$(pa_api_request POST "${PA_API}/projects" \
  --header "Content-Type: application/json" \
  --data '{"name":"example"}')
[[ "$response" == '{"ok":true}' ]]
grep -q -- '-X POST' "$CURL_CALL_LOG"
grep -q -- 'PRIVATE-TOKEN: test-token' "$CURL_CALL_LOG"
grep -q -- 'Content-Type: application/json' "$CURL_CALL_LOG"
grep -q -- '--data {"name":"example"}' "$CURL_CALL_LOG"
grep -q -- 'https://gitlab.com/api/v4/projects' "$CURL_CALL_LOG"

: >"$CURL_CALL_LOG"
response=$(pa_api_request GET "${PA_API}/version")
[[ "$response" == '{"ok":true}' ]]
grep -q -- '-X GET' "$CURL_CALL_LOG"

: >"$CURL_CALL_LOG"
response=$(pa_api_get "${PA_API}/version")
[[ "$response" == '{"ok":true}' ]]
grep -q -- '-X GET' "$CURL_CALL_LOG"

echo "platform-adapter generic request contract: ok"
