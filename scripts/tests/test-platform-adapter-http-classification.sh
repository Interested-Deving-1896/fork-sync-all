#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source "${repo_root}/scripts/includes/platform-adapter.sh"
export PA_AUTH_HEADER="Authorization: token test"
_PA_HEADER_TMP="$tmp/headers"
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat >"$tmp/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -e
count_file="${CURL_COUNT_FILE}"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" >"$count_file"
header_file=""
while (($#)); do
  case "$1" in
    -D) header_file="$2"; shift 2 ;;
    -w|-H) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
case "${CURL_MODE}" in
  forbidden)
    printf 'HTTP/1.1 403 Forbidden\r\n\r\n' >"$header_file"
    printf '{"message":"Resource not accessible"}\n403'
    ;;
  limited)
    if (( count == 1 )); then
      printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\n\r\n' >"$header_file"
      printf '{"message":"rate limit exceeded"}\n429'
    else
      printf 'HTTP/1.1 200 OK\r\nX-RateLimit-Remaining: 9\r\nX-RateLimit-Reset: 1900000000\r\n\r\n' >"$header_file"
      printf '{"ok":true}\n200'
    fi
    ;;
  transport)
    : >"$header_file"
    exit 7
    ;;
esac
CURL
chmod +x "$tmp/bin/"*
export CURL_COUNT_FILE="$tmp/count"

export CURL_MODE=forbidden
: >"$CURL_COUNT_FILE"
if pa_api_get "https://forge.example/api/test" >/dev/null; then
  echo "403 permission response unexpectedly succeeded" >&2; exit 1
fi
[[ "$PA_LAST_HTTP_STATUS" == "403" ]]
[[ "$(cat "$CURL_COUNT_FILE")" == "1" ]]

export CURL_MODE=limited
: >"$CURL_COUNT_FILE"
body="$(pa_api_get "https://forge.example/api/test")"
[[ "$body" == '{"ok":true}' ]]
[[ "$PA_LAST_HTTP_STATUS" == "200" ]]
[[ "$PA_LAST_RETRY_AFTER" == "1" ]]
[[ "$PA_LAST_RATE_LIMIT_RESET" == "1900000000" ]]
[[ "$(cat "$CURL_COUNT_FILE")" == "2" ]]

export CURL_MODE=transport
: >"$CURL_COUNT_FILE"
if pa_api_get "https://forge.example/api/test" >/dev/null; then
  echo "transport failure unexpectedly succeeded" >&2; exit 1
fi
[[ "$PA_LAST_HTTP_STATUS" == "000" ]]
echo "platform adapter HTTP classification: ok"
