#!/usr/bin/env bash
# GET /api/ocs/providers — list configured OCS providers
#
# Returns the list of known OCS providers with their base URLs.
# These match the providers shipped with KDE's attica library.
#
# Query params: none
# Auth: none required

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/adapter.sh"
source "${SCRIPT_DIR}/../../lib/http.sh"

adapter_provides "GET /api/ocs/providers"

respond_json 200 "$(python3 - << 'PYEOF'
import json
providers = [
    {
        "id":          "kde-look",
        "name":        "KDE Store",
        "base_url":    "https://api.kde-look.org/ocs/v1",
        "web_url":     "https://store.kde.org",
        "description": "Official KDE content store — themes, wallpapers, Plasma add-ons",
        "protocol":    "OCS v1.6",
        "auth":        "basic",
    },
    {
        "id":          "opendesktop",
        "name":        "OpenDesktop.org",
        "base_url":    "https://api.opendesktop.org/ocs/v1",
        "web_url":     "https://www.opendesktop.org",
        "description": "Original OCS provider — cross-desktop content store",
        "protocol":    "OCS v1.6",
        "auth":        "basic",
    },
    {
        "id":          "pling",
        "name":        "Pling.com",
        "base_url":    "https://api.pling.com/ocs/v1",
        "web_url":     "https://www.pling.com",
        "description": "Community content store with AppImage, Flatpak, Snap support",
        "protocol":    "OCS v1.6 + extensions",
        "auth":        "basic",
    },
]
print(json.dumps({"status": "ok", "providers": providers, "count": len(providers)}))
PYEOF
)"
