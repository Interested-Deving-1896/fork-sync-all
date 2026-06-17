#!/usr/bin/env bash
# GET /api/ocs/content/search — search OCS content store
#
# Query params:
#   provider   — provider ID from /api/ocs/providers (default: kde-look)
#   search     — search string
#   categories — comma-separated category IDs (optional)
#   page       — page number (default: 0)
#   pagesize   — results per page (default: 10, max: 100)
#   sort       — new|alpha|high|down (default: new)
#
# Auth: none required for public content

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/adapter.sh"
source "${SCRIPT_DIR}/../../lib/http.sh"
source "${SCRIPT_DIR}/../../lib/log.sh"

adapter_provides "GET /api/ocs/content/search"

PROVIDER_ID="$(query_param provider "kde-look")"
SEARCH="$(query_param search "")"
CATEGORIES="$(query_param categories "")"
PAGE="$(query_param page "0")"
PAGESIZE="$(query_param pagesize "10")"
SORT="$(query_param sort "new")"

# Resolve provider base URL
case "${PROVIDER_ID}" in
    kde-look)    BASE_URL="https://api.kde-look.org/ocs/v1" ;;
    opendesktop) BASE_URL="https://api.opendesktop.org/ocs/v1" ;;
    pling)       BASE_URL="https://api.pling.com/ocs/v1" ;;
    *)           respond_json 400 '{"error":"Unknown provider. Use /api/ocs/providers to list valid IDs."}'; exit 0 ;;
esac

OCS_FORMAT="${OCS_FORMAT:-json}"

# Build OCS v1 content search URL
# Spec: GET /content/data?search=<q>&categories=<ids>&page=<n>&pagesize=<n>&sortmode=<mode>
URL="${BASE_URL}/content/data"
PARAMS="format=${OCS_FORMAT}&page=${PAGE}&pagesize=${PAGESIZE}&sortmode=${SORT}"
[[ -n "${SEARCH}" ]]     && PARAMS="${PARAMS}&search=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${SEARCH}")"
[[ -n "${CATEGORIES}" ]] && PARAMS="${PARAMS}&categories=${CATEGORIES}"

log "OCS content search: ${URL}?${PARAMS}"

RESPONSE=$(curl -sf --max-time 15 \
    -H "Accept: application/json" \
    "${URL}?${PARAMS}" 2>/dev/null) || {
    respond_json 502 '{"error":"OCS provider unreachable","provider":"'"${PROVIDER_ID}"'","url":"'"${BASE_URL}"'"}'
    exit 0
}

# Wrap with metadata
python3 - << PYEOF
import json, sys
try:
    data = json.loads('''${RESPONSE}''')
    result = {
        "status": "ok",
        "provider": "${PROVIDER_ID}",
        "search": "${SEARCH}",
        "page": ${PAGE},
        "pagesize": ${PAGESIZE},
        "sort": "${SORT}",
        "data": data,
    }
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({"status": "ok", "provider": "${PROVIDER_ID}", "raw": '''${RESPONSE}'''}))
PYEOF
