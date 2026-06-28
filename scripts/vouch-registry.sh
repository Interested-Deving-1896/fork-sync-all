#!/usr/bin/env bash
# scripts/vouch-registry.sh
#
# Registry helpers for the FSA vouch/trust system.
#
# Provides:
#   registry_get_entry HANDLE        — print YAML block for a handle
#   registry_get_tier  HANDLE        — print tier number (1/2/3) or empty
#   registry_get_platforms HANDLE    — print "platform:handle" lines
#   registry_is_active HANDLE        — exit 0 if active, 1 if not
#   registry_add_entry YAML_FILE     — append a new entry from a YAML file
#   registry_sync_vouched_td         — regenerate .github/VOUCHED.td from registry
#   registry_list_tier TIER          — list handles at a given tier
#   registry_verify_platform HANDLE PLATFORM TOKEN  — run verification checks
#
# Environment:
#   REGISTRY_FILE   — path to vouch-registry.yml (default: config/vouch-registry.yml)
#   GH_TOKEN        — GitHub PAT for API calls
#   GITLAB_TOKEN    — GitLab PAT for API calls
#   DRY_RUN         — "true" to skip writes

set -euo pipefail

REGISTRY_FILE="${REGISTRY_FILE:-config/vouch-registry.yml}"
DRY_RUN="${DRY_RUN:-false}"

info()  { echo "[vouch-registry] $*" >&2; }
warn()  { echo "[vouch-registry][warn] $*" >&2; }
dry()   { echo "[vouch-registry][dry-run] $*" >&2; }

# ── Python helper (all registry reads go through this) ───────────────────────

_py_registry() {
    python3 - "$@" << 'PYEOF'
import sys, yaml, json, os, re

registry_file = os.environ.get("REGISTRY_FILE", "config/vouch-registry.yml")
with open(registry_file) as f:
    cfg = yaml.safe_load(f)

entries = cfg.get("entries", [])
cmd = sys.argv[1] if len(sys.argv) > 1 else ""

def find_entry(handle):
    h = handle.lower()
    for e in entries:
        if e.get("handle", "").lower() == h:
            return e
    return None

if cmd == "get_entry":
    handle = sys.argv[2]
    e = find_entry(handle)
    if e:
        print(yaml.dump([e], default_flow_style=False, allow_unicode=True), end="")

elif cmd == "get_tier":
    handle = sys.argv[2]
    e = find_entry(handle)
    if e and e.get("active", True):
        print(e.get("tier", ""))

elif cmd == "get_platforms":
    handle = sys.argv[2]
    e = find_entry(handle)
    if e:
        for platform, value in e.get("platforms", {}).items():
            if isinstance(value, list):
                for v in value:
                    print(f"{platform}:{v}")
            else:
                print(f"{platform}:{value}")

elif cmd == "is_active":
    handle = sys.argv[2]
    e = find_entry(handle)
    sys.exit(0 if (e and e.get("active", True)) else 1)

elif cmd == "list_tier":
    tier = int(sys.argv[2])
    for e in entries:
        if e.get("tier") == tier and e.get("active", True):
            print(e["handle"])

elif cmd == "list_all":
    for e in entries:
        if e.get("active", True):
            t = e.get("tier", "?")
            h = e.get("handle", "?")
            typ = e.get("type", "individual")
            print(f"{t}\t{h}\t{typ}")

elif cmd == "get_dispatch_scope":
    handle = sys.argv[2]
    e = find_entry(handle)
    if e:
        d = e.get("dispatch", {})
        print(d.get("scope", "none"))

elif cmd == "get_dispatch_workflows":
    handle = sys.argv[2]
    e = find_entry(handle)
    if e:
        d = e.get("dispatch", {})
        for wf in d.get("workflows", []):
            print(wf)

elif cmd == "get_platform_api":
    platform = sys.argv[2]
    field = sys.argv[3] if len(sys.argv) > 3 else ""
    api = cfg.get("platform_api", {}).get(platform, {})
    if field:
        print(api.get(field, ""))
    else:
        print(json.dumps(api))

elif cmd == "get_marker_prefix":
    print(cfg.get("verification_marker_prefix", "vouch:fsa:"))

elif cmd == "github_handles":
    # All active GitHub handles (for VOUCHED.td)
    for e in entries:
        if not e.get("active", True):
            continue
        gh = e.get("platforms", {}).get("github")
        if gh:
            handles = gh if isinstance(gh, list) else [gh]
            for h in handles:
                print(f"{e['tier']}\t{h}\t{e.get('type','individual')}")

elif cmd == "check_exists":
    handle = sys.argv[2]
    e = find_entry(handle)
    sys.exit(0 if e else 1)

PYEOF
}

# ── Public API ────────────────────────────────────────────────────────────────

registry_get_entry()    { _py_registry get_entry "$1"; }
registry_get_tier()     { _py_registry get_tier "$1"; }
registry_get_platforms(){ _py_registry get_platforms "$1"; }
registry_is_active()    { _py_registry is_active "$1"; }
registry_list_tier()    { _py_registry list_tier "$1"; }
registry_list_all()     { _py_registry list_all; }
registry_check_exists() { _py_registry check_exists "$1"; }

registry_get_dispatch_scope()     { _py_registry get_dispatch_scope "$1"; }
registry_get_dispatch_workflows() { _py_registry get_dispatch_workflows "$1"; }

# ── VOUCHED.td sync ───────────────────────────────────────────────────────────

registry_sync_vouched_td() {
    local vouched_file="${1:-.github/VOUCHED.td}"
    local now
    now=$(date -u '+%Y-%m-%d %H:%M UTC')

    info "Syncing registry → ${vouched_file}"

    # Build new content
    local new_content
    new_content=$(python3 - << 'PYEOF'
import yaml, os, sys
from datetime import datetime, timezone

registry_file = os.environ.get("REGISTRY_FILE", "config/vouch-registry.yml")
with open(registry_file) as f:
    cfg = yaml.safe_load(f)

entries = cfg.get("entries", [])
now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

lines = [
    "# VOUCHED.td — trusted contributors for fork-sync-all",
    "#",
    "# AUTO-GENERATED by scripts/vouch-registry.sh from config/vouch-registry.yml",
    f"# Last updated: {now}",
    "#",
    "# Format: platform:handle  (one per line, sorted alphabetically within tier)",
    "# Tiers: 1=Creator, 2=Org/Project, 3=Contributor",
    "#",
    "# Edit config/vouch-registry.yml to add/remove entries.",
    "# Run: bash scripts/vouch-registry.sh sync",
    "",
]

for tier_num in [1, 2, 3]:
    tier_entries = [e for e in entries if e.get("tier") == tier_num and e.get("active", True)]
    if not tier_entries:
        continue

    tier_labels = {1: "Tier 1 — Creator / Maintainer", 2: "Tier 2 — Organizations / Projects", 3: "Tier 3 — Contributors"}
    lines.append(f"# ── {tier_labels[tier_num]} {'─' * (60 - len(tier_labels[tier_num]))}")
    lines.append("")

    # Collect all platform:handle pairs for this tier
    pairs = []
    for e in tier_entries:
        handle = e["handle"]
        for platform, value in e.get("platforms", {}).items():
            handles = value if isinstance(value, list) else [value]
            for h in handles:
                pairs.append((f"{platform}:{h}", handle, e.get("role", "")))

    pairs.sort(key=lambda x: x[0].lower())
    for pair, canonical, role in pairs:
        comment = f"  # {canonical}" + (f" — {role}" if role else "")
        lines.append(f"{pair}{comment}")

    lines.append("")

print("\n".join(lines))
PYEOF
)

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry "Would write ${vouched_file}:"
        echo "$new_content" >&2
        return 0
    fi

    echo "$new_content" > "${vouched_file}"
    info "Written: ${vouched_file}"
}

# ── Platform verification ─────────────────────────────────────────────────────

registry_verify_platform() {
    local handle="$1"
    local platform="$2"
    local platform_handle="$3"
    local token="${4:-}"
    local methods_found=()

    local marker_prefix
    marker_prefix=$(_py_registry get_marker_prefix)
    local expected_marker="${marker_prefix}${handle}"

    info "Verifying ${platform}:${platform_handle} for ${handle}"
    info "  Expected marker: ${expected_marker}"

    local api_base
    api_base=$(_py_registry get_platform_api "${platform}" api_base)

    if [[ -z "$api_base" ]]; then
        warn "No API config for platform: ${platform}"
        echo "declaration"
        return 0
    fi

    local auth_header=""
    [[ -n "$token" ]] && auth_header="Authorization: Bearer ${token}"

    # ── Method 1: bio-marker ─────────────────────────────────────────────────
    local bio=""
    if [[ "$platform" == "github" && -n "$token" ]]; then
        bio=$(curl -sf \
            -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github+json" \
            "${api_base}/users/${platform_handle}" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('bio','') or '')" 2>/dev/null || echo "")
    elif [[ "$platform" == "gitlab" && -n "$token" ]]; then
        bio=$(curl -sf \
            -H "PRIVATE-TOKEN: ${token}" \
            "${api_base}/users?username=${platform_handle}" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('bio','') or '' if d else '')" 2>/dev/null || echo "")
    fi

    if echo "$bio" | grep -qF "${expected_marker}"; then
        info "  ✓ bio-marker found"
        methods_found+=("bio-marker")
    fi

    # ── Method 2: repo-marker ────────────────────────────────────────────────
    local marker_content=""
    if [[ "$platform" == "github" && -n "$token" ]]; then
        marker_content=$(curl -sf \
            "https://raw.githubusercontent.com/${platform_handle}/.vouch-fsa/main/.vouch-fsa" \
            2>/dev/null || echo "")
    elif [[ "$platform" == "gitlab" && -n "$token" ]]; then
        marker_content=$(curl -sf \
            -H "PRIVATE-TOKEN: ${token}" \
            "${api_base}/projects/${platform_handle}%2F.vouch-fsa/repository/files/.vouch-fsa/raw?ref=main" \
            2>/dev/null || echo "")
    fi

    if echo "$marker_content" | grep -qF "${expected_marker}"; then
        info "  ✓ repo-marker found"
        methods_found+=("repo-marker")
    fi

    # ── Method 3: cross-link ─────────────────────────────────────────────────
    # Check if GitHub profile links to GitLab and vice versa
    if [[ "$platform" == "github" && -n "$token" ]]; then
        local gh_website
        gh_website=$(curl -sf \
            -H "Authorization: token ${token}" \
            "${api_base}/users/${platform_handle}" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('blog','') or d.get('html_url',''))" 2>/dev/null || echo "")
        # Check if any known GitLab handle appears in the profile
        local gitlab_handles
        gitlab_handles=$(registry_get_platforms "${handle}" | grep "^gitlab:" | cut -d: -f2)
        for gl_handle in $gitlab_handles; do
            if echo "$gh_website $bio" | grep -qi "gitlab.com/${gl_handle}"; then
                info "  ✓ cross-link found (gitlab.com/${gl_handle})"
                methods_found+=("cross-link")
                break
            fi
        done
    fi

    # ── Method 4: org-member ─────────────────────────────────────────────────
    if [[ "$platform" == "github" && -n "$token" ]]; then
        # Check if user is a public member of any Tier 2 org
        local tier2_orgs
        tier2_orgs=$(registry_list_tier 2)
        for org_handle in $tier2_orgs; do
            local org_gh
            org_gh=$(_py_registry get_platforms "${org_handle}" | grep "^github:" | cut -d: -f2 | head -1)
            [[ -z "$org_gh" ]] && continue
            local member_status
            member_status=$(curl -sf -o /dev/null -w "%{http_code}" \
                -H "Authorization: token ${token}" \
                "${api_base}/orgs/${org_gh}/public_members/${platform_handle}" 2>/dev/null || echo "000")
            if [[ "$member_status" == "204" ]]; then
                info "  ✓ org-member: ${org_gh}"
                methods_found+=("org-member")
                break
            fi
        done
    fi

    if [[ ${#methods_found[@]} -eq 0 ]]; then
        warn "  No verification methods succeeded — defaulting to declaration"
        echo "declaration"
    else
        printf '%s\n' "${methods_found[@]}"
    fi
}

# ── Add entry ─────────────────────────────────────────────────────────────────

registry_add_entry() {
    local yaml_fragment="$1"
    local handle
    handle=$(echo "$yaml_fragment" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print(d.get('handle',''))")

    if [[ -z "$handle" ]]; then
        warn "Cannot add entry: no handle found in YAML"
        return 1
    fi

    if registry_check_exists "$handle" 2>/dev/null; then
        warn "Entry already exists for handle: ${handle}"
        return 1
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry "Would add entry for: ${handle}"
        echo "$yaml_fragment" >&2
        return 0
    fi

    # Append to entries list in registry file
    python3 - "${REGISTRY_FILE}" << PYEOF
import yaml, sys

registry_file = sys.argv[1]
with open(registry_file) as f:
    content = f.read()

new_entry_yaml = """${yaml_fragment}"""
new_entry = yaml.safe_load(new_entry_yaml)

# Find the end of the entries: block and append
# Simple approach: append before the platform_api: section
marker = "\n# ── Platform API Hub"
if marker in content:
    insert_pos = content.index(marker)
    new_block = yaml.dump([new_entry], default_flow_style=False, allow_unicode=True, indent=2)
    # Indent for entries list
    indented = "\n".join("  " + line if line else "" for line in new_block.splitlines())
    content = content[:insert_pos] + "\n" + indented + "\n" + content[insert_pos:]
    with open(registry_file, "w") as f:
        f.write(content)
    print(f"Added entry: {new_entry.get('handle')}")
else:
    print("ERROR: Could not find insertion point in registry file", file=sys.stderr)
    sys.exit(1)
PYEOF
    info "Added entry for: ${handle}"
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-help}"
    shift || true
    case "$cmd" in
        sync)       registry_sync_vouched_td "${1:-.github/VOUCHED.td}" ;;
        list)       registry_list_all ;;
        tier)       registry_list_tier "${1:-3}" ;;
        get)        registry_get_entry "${1:?handle required}" ;;
        tier-of)    registry_get_tier "${1:?handle required}" ;;
        platforms)  registry_get_platforms "${1:?handle required}" ;;
        verify)     registry_verify_platform "${1:?handle}" "${2:?platform}" "${3:?platform_handle}" "${4:-}" ;;
        help|*)
            echo "Usage: vouch-registry.sh <command> [args]"
            echo "Commands:"
            echo "  sync [file]          Regenerate VOUCHED.td from registry"
            echo "  list                 List all active entries"
            echo "  tier <N>             List handles at tier N"
            echo "  get <handle>         Show entry for handle"
            echo "  tier-of <handle>     Print tier number for handle"
            echo "  platforms <handle>   List platform:handle pairs for entry"
            echo "  verify <handle> <platform> <platform_handle> [token]"
            ;;
    esac
fi
