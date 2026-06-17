#!/usr/bin/env bash
# GET /api/ocs/eco/certified — list eco-certified software
#
# Returns software known to have KDE Eco / Blue Angel certification,
# plus checks the Green Web Foundation API for hosting status of
# any provided URL.
#
# Query params:
#   check_url  — URL to check for green hosting (optional)
#   provider   — OCS provider to search for eco-tagged content (default: kde-look)
#
# Stubs:
#   KEcoLab integration — requires GitLab CI + physical power meter.
#   Stub returns the lab URL and setup instructions.
#
# Auth: none required

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/adapter.sh"
source "${SCRIPT_DIR}/../../lib/http.sh"
source "${SCRIPT_DIR}/../../lib/log.sh"

adapter_provides "GET /api/ocs/eco/certified"

CHECK_URL="$(query_param check_url "")"
PROVIDER_ID="$(query_param provider "kde-look")"

# ── Known eco-certified software ──────────────────────────────────────────────
CERTIFIED='[
  {
    "name": "Okular",
    "description": "KDE PDF reader and universal document viewer",
    "certification": "Blue Angel DE-UZ 215",
    "certified_year": 2022,
    "url": "https://okular.kde.org",
    "source": "https://invent.kde.org/graphics/okular",
    "criteria": ["no telemetry","FOSS license","runs on old hardware","minimal resource use","no forced updates"]
  }
]'

# ── Green Web Foundation check ────────────────────────────────────────────────
GREEN_RESULT="null"
if [[ -n "${CHECK_URL}" ]]; then
    log "Checking green hosting for: ${CHECK_URL}"
    ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${CHECK_URL}")
    GWF_RESPONSE=$(curl -sf --max-time 10 \
        "https://api.thegreenwebfoundation.org/api/v3/greencheck/${ENCODED}" \
        2>/dev/null) || GWF_RESPONSE='{"error":"Green Web Foundation API unreachable"}'
    GREEN_RESULT="${GWF_RESPONSE}"
fi

# ── KEcoLab stub ──────────────────────────────────────────────────────────────
# KEcoLab is KDE's remote energy measurement lab. It requires:
#   1. A GitLab CI pipeline (see .gitlab-ci-eco.yml in this repo)
#   2. Physical power meter connected to KDE's test hardware
#   3. KdeEcoTest scripts simulating user interactions
#   4. Submission to: https://invent.kde.org/teams/eco/remote-eco-lab
# This stub returns setup instructions for GitLab deployment.
KECO_STUB='{
  "status": "stub",
  "description": "KEcoLab requires physical power meter hardware at KDE infrastructure",
  "setup": {
    "step_1": "Create KdeEcoTest scripts simulating your app user interactions",
    "step_2": "Add .gitlab-ci-eco.yml to your repo (see scripts/eco/gitlab-ci-eco.yml.tpl)",
    "step_3": "Submit to KEcoLab: https://invent.kde.org/teams/eco/remote-eco-lab",
    "step_4": "Receive energy consumption report (watt-hours per use case)",
    "step_5": "Apply for Blue Angel DE-UZ 215 certification if criteria met"
  },
  "resources": {
    "keco_lab":    "https://invent.kde.org/teams/eco/remote-eco-lab",
    "handbook":    "https://eco.kde.org/be4foss-handbook",
    "keco_test":   "https://invent.kde.org/teams/eco/feep/-/tree/master/tools/KdeEcoTest",
    "blue_angel":  "https://www.blauer-engel.de/en/certification/criteria",
    "criteria_pdf":"https://www.blauer-engel.de/sites/default/files/vergabegrundlagen-dokumente/DE-UZ-215-Vergabegrundlagen-2020-01-01.pdf"
  }
}'

python3 - << PYEOF
import json, sys

certified = json.loads('''${CERTIFIED}''')
green = ${GREEN_RESULT}
keco = json.loads('''${KECO_STUB}''')

result = {
    "status": "ok",
    "certified_software": certified,
    "keco_lab": keco,
}

if green is not None:
    result["green_hosting_check"] = {
        "url": "${CHECK_URL}",
        "result": green,
    }

print(json.dumps(result, indent=2))
PYEOF
