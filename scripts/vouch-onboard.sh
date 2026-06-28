#!/usr/bin/env bash
# scripts/vouch-onboard.sh
#
# Onboarding logic for the FSA vouch/trust system.
#
# Modes:
#   admin     — Tier 1/2 admin-run onboarding (workflow_dispatch)
#   self      — Tier 3 self-service onboarding (issue form or workflow_dispatch)
#   auto      — Auto-detect from org membership (scheduled)
#   seed      — Sync seed data from registry (initial setup)
#
# Environment (all modes):
#   MODE              — admin | self | auto | seed
#   DRY_RUN           — true | false
#   GH_TOKEN          — GitHub PAT
#   GITLAB_TOKEN      — GitLab PAT (optional)
#   REGISTRY_FILE     — path to vouch-registry.yml
#   REPO              — owner/repo
#
# Environment (admin mode):
#   HANDLE            — canonical handle for the new entry
#   TIER              — 1 | 2 | 3
#   TYPE              — individual | org | project
#   ROLE              — human-readable role
#   GITHUB_HANDLE     — GitHub username/org (optional)
#   GITLAB_HANDLES    — comma-separated GitLab handles (optional)
#   CODEBERG_HANDLE   — Codeberg handle (optional)
#   PROFILE_URL       — canonical profile URL
#   ADDED_BY          — handle of the admin adding this entry
#   SKIP_VERIFY       — true | false (skip platform verification)
#
# Environment (self mode):
#   REQUESTER_GITHUB  — GitHub handle of the requester
#   GITLAB_HANDLES    — comma-separated GitLab handles to link (optional)
#   PROFILE_URL       — canonical profile URL (optional)
#   ISSUE_NUMBER      — GitHub issue number (for comment feedback)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-config/vouch-registry.yml}"
DRY_RUN="${DRY_RUN:-false}"
MODE="${MODE:-seed}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
GH_API="https://api.github.com"

# shellcheck source=scripts/vouch-registry.sh
source "${SCRIPT_DIR}/vouch-registry.sh"

info()  { echo "[vouch-onboard] $*" >&2; }
warn()  { echo "[vouch-onboard][warn] $*" >&2; }
die()   { echo "[vouch-onboard][error] $*" >&2; exit 1; }

# ── GitHub issue comment helper ───────────────────────────────────────────────

post_issue_comment() {
    local issue_number="$1"
    local body="$2"
    [[ -z "$issue_number" || -z "${GH_TOKEN:-}" ]] && return 0
    local _body_file
    _body_file=$(mktemp)
    python3 -c "import json,sys; print(json.dumps({'body':sys.argv[1]},separators=(',',':')))" "$body" > "$_body_file"
    curl -sf -X POST \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${GH_API}/repos/${REPO}/issues/${issue_number}/comments" \
        -d @"$_body_file" > /dev/null 2>&1 || warn "Failed to post issue comment"
    rm -f "$_body_file"
}

close_issue() {
    local issue_number="$1"
    local reason="${2:-completed}"
    [[ -z "$issue_number" || -z "${GH_TOKEN:-}" ]] && return 0
    local _body_file
    _body_file=$(mktemp)
    python3 -c "import json,sys; print(json.dumps({'state':'closed','state_reason':sys.argv[1]},separators=(',',':')))" "$reason" > "$_body_file"
    curl -sf -X PATCH \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${GH_API}/repos/${REPO}/issues/${issue_number}" \
        -d @"$_body_file" > /dev/null 2>&1 || warn "Failed to close issue"
    rm -f "$_body_file"
}

# ── Auto-detect dispatch scope for Tier 2 orgs ───────────────────────────────

auto_detect_dispatch_workflows() {
    local org_github_handle="$1"
    local token="${GH_TOKEN:-}"
    local workflows=()

    [[ -z "$token" ]] && echo "[]" && return 0

    info "Auto-detecting dispatchable workflows for org: ${org_github_handle}"

    # Get all workflow files in the repo
    local all_workflows
    all_workflows=$(curl -sf \
        -H "Authorization: token ${token}" \
        "${GH_API}/repos/${REPO}/actions/workflows?per_page=100" \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
for w in d.get('workflows',[]):
    print(w['path'].replace('.github/workflows/','').replace('.yml',''))
" 2>/dev/null || echo "")

    # Filter to workflows that are org-safe (not Tier 1 critical)
    local tier1_workflows
    tier1_workflows=$(python3 -c "
import yaml
d = yaml.safe_load(open('${REGISTRY_FILE}'))
# Tier 1 dispatch scope = all, so we need to know what's critical
# Read from workflow-priority-tiers.yml
import yaml
t = yaml.safe_load(open('config/workflow-priority-tiers.yml'))
tier1 = [w['name'].lower().replace(' ','-') for w in t.get('tiers',[]) if w.get('tier')==1]
print('\n'.join(tier1))
" 2>/dev/null || echo "")

    while IFS= read -r wf; do
        [[ -z "$wf" ]] && continue
        # Skip Tier 1 critical workflows
        if echo "$tier1_workflows" | grep -qi "^${wf}$"; then
            continue
        fi
        # Skip internal/maintenance workflows
        case "$wf" in
            queue-manager|quota-reserve|quota-monitor|rotate-token|token-health*) continue ;;
            flush-*|pre-flush-*|post-flush-*|critical-deploy*) continue ;;
            validate-config|cancel-*) continue ;;
        esac
        workflows+=("$wf")
    done <<< "$all_workflows"

    python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${workflows[@]:-}"
}

# ── Build YAML entry ──────────────────────────────────────────────────────────

build_entry_yaml() {
    local handle="$1"
    local tier="$2"
    local type="$3"
    local role="$4"
    local added_by="$5"
    local profile_url="$6"
    local github_handle="${7:-}"
    local gitlab_handles="${8:-}"   # comma-separated
    local codeberg_handle="${9:-}"
    local verification_methods="${10:-declaration}"
    local dispatch_scope="${11:-none}"
    local dispatch_workflows="${12:-}"  # JSON array string
    local notes="${13:-}"

    local today
    today=$(date -u '+%Y-%m-%d')

    python3 - << PYEOF
import yaml, json

entry = {
    "handle": "${handle}",
    "tier": ${tier},
    "type": "${type}",
    "role": "${role}",
    "active": True,
    "added_by": "${added_by}",
    "added_at": "${today}",
    "platforms": {},
    "url": "${profile_url}",
    "verification": [v.strip() for v in "${verification_methods}".split(",") if v.strip()],
    "dispatch": {"scope": "${dispatch_scope}"},
}

if "${github_handle}":
    entry["platforms"]["github"] = "${github_handle}"

if "${gitlab_handles}":
    gl = [h.strip() for h in "${gitlab_handles}".split(",") if h.strip()]
    entry["platforms"]["gitlab"] = gl if len(gl) > 1 else gl[0]

if "${codeberg_handle}":
    entry["platforms"]["codeberg"] = "${codeberg_handle}"

dispatch_wfs_raw = '${dispatch_workflows}'
if dispatch_wfs_raw and dispatch_wfs_raw != "[]":
    try:
        wfs = json.loads(dispatch_wfs_raw)
        if wfs:
            entry["dispatch"]["workflows"] = wfs
    except Exception:
        pass

if "${notes}":
    entry["notes"] = "${notes}"

print(yaml.dump(entry, default_flow_style=False, allow_unicode=True), end="")
PYEOF
}

# ── Mode: seed ────────────────────────────────────────────────────────────────

mode_seed() {
    info "Seeding VOUCHED.td from registry..."
    registry_sync_vouched_td ".github/VOUCHED.td"
    info "Seed complete."
}

# ── Mode: admin ───────────────────────────────────────────────────────────────

mode_admin() {
    local handle="${HANDLE:?HANDLE required}"
    local tier="${TIER:?TIER required}"
    local type="${TYPE:-individual}"
    local role="${ROLE:-Contributor}"
    local added_by="${ADDED_BY:?ADDED_BY required}"
    local profile_url="${PROFILE_URL:-}"
    local github_handle="${GITHUB_HANDLE:-}"
    local gitlab_handles="${GITLAB_HANDLES:-}"
    local codeberg_handle="${CODEBERG_HANDLE:-}"
    local skip_verify="${SKIP_VERIFY:-false}"

    info "Admin onboarding: handle=${handle} tier=${tier} type=${type}"

    # Check not already registered
    if registry_check_exists "$handle" 2>/dev/null; then
        warn "Handle already registered: ${handle}"
        exit 0
    fi

    # Verify requester is Tier 1
    local requester_tier
    requester_tier=$(registry_get_tier "${added_by}" 2>/dev/null || echo "")
    if [[ "$requester_tier" != "1" ]]; then
        die "Only Tier 1 maintainers can run admin onboarding. ${added_by} is tier ${requester_tier:-unknown}."
    fi

    # Platform verification
    local verification_methods="declaration"
    if [[ "$skip_verify" != "true" && -n "$github_handle" ]]; then
        local methods
        methods=$(registry_verify_platform "${handle}" "github" "${github_handle}" "${GH_TOKEN:-}" 2>/dev/null || echo "declaration")
        verification_methods=$(echo "$methods" | tr '\n' ',' | sed 's/,$//')
    fi

    # Auto-detect dispatch scope for Tier 2
    local dispatch_scope="none"
    local dispatch_workflows="[]"
    if [[ "$tier" == "1" ]]; then
        dispatch_scope="all"
    elif [[ "$tier" == "2" && -n "$github_handle" ]]; then
        dispatch_scope="scoped"
        dispatch_workflows=$(auto_detect_dispatch_workflows "$github_handle")
    fi

    # Build and add entry
    local entry_yaml
    entry_yaml=$(build_entry_yaml \
        "$handle" "$tier" "$type" "$role" "$added_by" \
        "$profile_url" "$github_handle" "$gitlab_handles" "$codeberg_handle" \
        "$verification_methods" "$dispatch_scope" "$dispatch_workflows" "")

    info "Entry YAML:"
    echo "$entry_yaml" >&2

    registry_add_entry "$entry_yaml"
    registry_sync_vouched_td ".github/VOUCHED.td"

    info "Admin onboarding complete for: ${handle} (Tier ${tier})"
}

# ── Mode: self ────────────────────────────────────────────────────────────────

mode_self() {
    local requester="${REQUESTER_GITHUB:?REQUESTER_GITHUB required}"
    local gitlab_handles="${GITLAB_HANDLES:-}"
    local profile_url="${PROFILE_URL:-https://github.com/${requester}}"
    local issue_number="${ISSUE_NUMBER:-}"

    info "Self-service onboarding: requester=${requester}"

    # Check not already registered
    if registry_check_exists "$requester" 2>/dev/null; then
        warn "Handle already registered: ${requester}"
        post_issue_comment "$issue_number" "✅ **Already registered** — \`${requester}\` is already in the vouch registry. No action needed."
        close_issue "$issue_number" "completed"
        exit 0
    fi

    # Verify GitHub account exists
    local gh_user_status
    gh_user_status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GH_TOKEN}" \
        "${GH_API}/users/${requester}" 2>/dev/null || echo "000")
    if [[ "$gh_user_status" != "200" ]]; then
        post_issue_comment "$issue_number" "❌ **GitHub account not found** — could not find GitHub user \`${requester}\`. Please check the handle and try again."
        close_issue "$issue_number" "not_planned"
        die "GitHub user not found: ${requester}"
    fi

    # Run platform verification
    local verification_methods
    verification_methods=$(registry_verify_platform \
        "$requester" "github" "$requester" "${GH_TOKEN:-}" 2>/dev/null || echo "declaration")

    # Check org membership (auto-elevate if member of Tier 2 org)
    local tier=3
    local org_member_of=""
    local tier2_orgs
    tier2_orgs=$(registry_list_tier 2 2>/dev/null || echo "")
    for org_handle in $tier2_orgs; do
        local org_gh
        org_gh=$(registry_get_platforms "$org_handle" 2>/dev/null | grep "^github:" | cut -d: -f2 | head -1 || echo "")
        [[ -z "$org_gh" ]] && continue
        local member_status
        member_status=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "Authorization: token ${GH_TOKEN}" \
            "${GH_API}/orgs/${org_gh}/public_members/${requester}" 2>/dev/null || echo "000")
        if [[ "$member_status" == "204" ]]; then
            org_member_of="$org_gh"
            info "  Requester is public member of Tier 2 org: ${org_gh}"
            break
        fi
    done

    # Build entry
    local entry_yaml
    entry_yaml=$(build_entry_yaml \
        "$requester" "$tier" "individual" "Contributor" \
        "Interested-Deving-1896" "$profile_url" \
        "$requester" "$gitlab_handles" "" \
        "$verification_methods" "none" "[]" \
        "${org_member_of:+Member of ${org_member_of}}")

    registry_add_entry "$entry_yaml"
    registry_sync_vouched_td ".github/VOUCHED.td"

    # Post success comment
    local verify_list
    verify_list=$(echo "$verification_methods" | tr ',' '\n' | sed 's/^/- /' | tr '\n' '\n')
    post_issue_comment "$issue_number" "✅ **Vouch registration complete**

**Handle:** \`${requester}\`
**Tier:** 3 (Contributor)
**Verification methods:** 
${verify_list}

Your GitHub account is now registered in the FSA vouch registry. PRs from \`${requester}\` on non-sensitive paths will auto-pass the vouch gate.

To link additional platform accounts (GitLab, Codeberg, etc.), re-run the onboarding workflow with your handles filled in."

    close_issue "$issue_number" "completed"
    info "Self-service onboarding complete for: ${requester}"
}

# ── Mode: auto ────────────────────────────────────────────────────────────────

mode_auto() {
    info "Auto-detection scan: checking Tier 2 org members..."
    local new_count=0

    local tier2_orgs
    tier2_orgs=$(registry_list_tier 2 2>/dev/null || echo "")

    for org_handle in $tier2_orgs; do
        local org_gh
        org_gh=$(registry_get_platforms "$org_handle" 2>/dev/null | grep "^github:" | cut -d: -f2 | head -1 || echo "")
        [[ -z "$org_gh" ]] && continue

        info "Scanning org members: ${org_gh}"
        local members
        members=$(curl -sf \
            -H "Authorization: token ${GH_TOKEN}" \
            "${GH_API}/orgs/${org_gh}/public_members?per_page=100" \
            | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d: print(m['login'])
" 2>/dev/null || echo "")

        while IFS= read -r member; do
            [[ -z "$member" ]] && continue
            if ! registry_check_exists "$member" 2>/dev/null; then
                info "  New org member found: ${member} — auto-registering at Tier 3"
                REQUESTER_GITHUB="$member" \
                PROFILE_URL="https://github.com/${member}" \
                ISSUE_NUMBER="" \
                    mode_self
                new_count=$((new_count + 1))
            fi
        done <<< "$members"
    done

    info "Auto-detection complete. New entries: ${new_count}"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

case "${MODE}" in
    admin)  mode_admin ;;
    self)   mode_self ;;
    auto)   mode_auto ;;
    seed)   mode_seed ;;
    *)      die "Unknown MODE: ${MODE}. Use: admin | self | auto | seed" ;;
esac
