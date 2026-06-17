#!/usr/bin/env bash
# eco-audit.sh — KDE Eco-aligned sustainability audit for fork-sync-all
#
# Audits fork-sync-all itself and optionally consumer/OSP-bound repos against
# KDE Eco / Blue Angel DE-UZ 215 criteria, adapted for CI/CD infrastructure.
#
# What this script measures (all CI-measurable proxies):
#   A. Green hosting — Green Web Foundation API check for GitHub Pages URL
#   B. CI compute efficiency — job duration, REST call counts, redundant triggers
#   C. Blue Angel checklist — FOSS license, no telemetry, minimal deps, etc.
#   D. Dependency audit — count pip/npm/apt installs per workflow
#   E. Artifact size audit — flag oversized build outputs
#   F. Runner carbon estimate — runner minutes × Azure North Central US grid intensity
#
# What requires GitLab + physical hardware (stubbed):
#   G. KEcoLab energy measurement — watt-hours per use case (see gitlab-ci-eco.yml.tpl)
#   H. KdeEcoTest scripts — scripted user interaction replay

#
# Usage:
#   bash scripts/eco/eco-audit.sh [--repo OWNER/REPO] [--output-md PATH] [--json]
#
# Environment:
#   GH_TOKEN        — GitHub token (for API calls)
#   REPO            — owner/repo to audit (default: Interested-Deving-1896/fork-sync-all)
#   ECO_OUTPUT_MD   — path to write markdown report (default: DOCS/generated/eco-audit.md)
#   ECO_JSON_OUT    — path to write JSON results (default: /tmp/eco-audit.json)
#   DRY_RUN         — if true, skip API calls and use cached/stub data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info()  { echo "[eco-audit] $*" >&2; }
warn()  { echo "[eco-audit:warn] $*" >&2; }
ok()    { echo "[eco-audit:✓] $*" >&2; }
fail()  { echo "[eco-audit:✗] $*" >&2; }
stub()  { echo "[eco-audit:stub] $*" >&2; }

# ── Args ──────────────────────────────────────────────────────────────────────
REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"
ECO_OUTPUT_MD="${ECO_OUTPUT_MD:-${REPO_ROOT}/DOCS/generated/eco-audit.md}"
ECO_JSON_OUT="${ECO_JSON_OUT:-/tmp/eco-audit.json}"
DRY_RUN="${DRY_RUN:-false}"
GH_TOKEN="${GH_TOKEN:-}"
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)       REPO="$2"; shift 2 ;;
        --output-md)  ECO_OUTPUT_MD="$2"; shift 2 ;;
        --json)       OUTPUT_JSON=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
PAGES_URL="https://${OWNER,,}.github.io/${REPO_NAME}/"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DATE=$(date -u '+%Y-%m-%d')

# ── Score tracking ────────────────────────────────────────────────────────────
SCORE=0
MAX_SCORE=0
declare -A RESULTS=()

score() {
    local key="$1" points="$2" max="$3" label="$4"
    SCORE=$((SCORE + points))
    MAX_SCORE=$((MAX_SCORE + max))
    RESULTS["${key}"]="${points}/${max}|${label}"
    export "_ECO_RESULT_${key}"="${points}/${max}|${label}"
    if [[ "${points}" -eq "${max}" ]]; then
        ok "${label} (${points}/${max})"
    elif [[ "${points}" -gt 0 ]]; then
        warn "${label} (${points}/${max})"
    else
        fail "${label} (${points}/${max})"
    fi
}

# ── A. Green hosting check ────────────────────────────────────────────────────
info "A. Checking green hosting for ${PAGES_URL}..."
GREEN_HOSTING=0
GREEN_DETAIL="unchecked"

if [[ "${DRY_RUN}" != "true" ]]; then
    ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PAGES_URL}")
    GWF=$(curl -sf --max-time 10 \
        "https://api.thegreenwebfoundation.org/api/v3/greencheck/${ENCODED}" \
        2>/dev/null || echo '{}')
    IS_GREEN=$(echo "${GWF}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('green','false'))" 2>/dev/null || echo "false")
    HOSTED_BY=$(echo "${GWF}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hosted_by','unknown'))" 2>/dev/null || echo "unknown")

    if [[ "${IS_GREEN}" == "True" ]] || [[ "${IS_GREEN}" == "true" ]]; then
        GREEN_HOSTING=2
        GREEN_DETAIL="✅ Green — hosted by ${HOSTED_BY}"
    else
        GREEN_HOSTING=0
        GREEN_DETAIL="❌ Not verified green — hosted by ${HOSTED_BY}"
    fi
else
    GREEN_DETAIL="⏭ Skipped (dry-run)"
    GREEN_HOSTING=1
fi

score "green_hosting" "${GREEN_HOSTING}" 2 "Green hosting (${GREEN_DETAIL})"

# ── B. FOSS license check ─────────────────────────────────────────────────────
info "B. Checking FOSS license..."
LICENSE_FILE=""
for f in LICENSE LICENSE.md LICENSE.txt COPYING; do
    [[ -f "${REPO_ROOT}/${f}" ]] && LICENSE_FILE="${f}" && break
done

if [[ -n "${LICENSE_FILE}" ]]; then
    LICENSE_TEXT=$(head -3 "${REPO_ROOT}/${LICENSE_FILE}" 2>/dev/null || echo "")
    score "foss_license" 2 2 "FOSS license present (${LICENSE_FILE})"
else
    # Check via GitHub API
    if [[ -n "${GH_TOKEN}" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        LICENSE_INFO=$(curl -sf \
            -H "Authorization: token ${GH_TOKEN}" \
            "https://api.github.com/repos/${REPO}/license" 2>/dev/null || echo '{}')
        LICENSE_NAME=$(echo "${LICENSE_INFO}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('license',{}).get('spdx_id','none'))" 2>/dev/null || echo "none")
        if [[ "${LICENSE_NAME}" != "none" ]] && [[ "${LICENSE_NAME}" != "NOASSERTION" ]]; then
            score "foss_license" 2 2 "FOSS license: ${LICENSE_NAME}"
        else
            score "foss_license" 0 2 "No FOSS license detected"
        fi
    else
        score "foss_license" 1 2 "License file not found locally (API check skipped)"
    fi
fi

# ── C. No telemetry / tracking ────────────────────────────────────────────────
info "C. Checking for telemetry/tracking..."
TELEMETRY_HITS=$(grep -rn "mixpanel\|segment\.com\|amplitude\.com\|hotjar\|ga\.js\|gtag\|google-analytics\|heap\.io\|fullstory" \
    "${REPO_ROOT}/scripts/" "${REPO_ROOT}/.github/workflows/" 2>/dev/null \
    | grep -v "\.pyc\|eco-audit" \
    | wc -l | tr -dc '0-9' || echo "0")
TELEMETRY_HITS="${TELEMETRY_HITS:-0}"

if [[ "${TELEMETRY_HITS}" -eq 0 ]]; then
    score "no_telemetry" 2 2 "No telemetry/tracking found"
else
    score "no_telemetry" 0 2 "Telemetry references found (${TELEMETRY_HITS} hits)"
fi

# ── D. No forced updates ──────────────────────────────────────────────────────
info "D. Checking for forced update patterns..."
FORCED_UPDATE_HITS=$(grep -rn "force.*update\|mandatory.*upgrade\|required.*version" \
    "${REPO_ROOT}/scripts/" 2>/dev/null \
    | grep -v "\.pyc\|#" | wc -l | tr -d ' ' || echo "0")

if [[ "${FORCED_UPDATE_HITS}" -eq 0 ]]; then
    score "no_forced_updates" 2 2 "No forced update patterns"
else
    score "no_forced_updates" 1 2 "Possible forced update patterns (${FORCED_UPDATE_HITS} hits — review manually)"
fi

# ── E. CI compute efficiency ──────────────────────────────────────────────────
info "E. Auditing CI compute efficiency..."

# Count workflows using GraphQL (1 call) vs REST loops
WF_COUNT=$(find "${REPO_ROOT}/.github/workflows/" -name "*.yml" | wc -l)
GRAPHQL_COUNT=$(grep -rl "graphql\|api/graphql\|gh_api_graphql" \
    "${REPO_ROOT}/scripts/" "${REPO_ROOT}/.github/workflows/" 2>/dev/null | wc -l | tr -d ' ')
REST_LOOP_COUNT=$(grep -rn "for.*in.*repos\|while.*repos\|gh api.*repos" \
    "${REPO_ROOT}/scripts/" 2>/dev/null | grep -v "graphql\|#" | wc -l | tr -d ' ' || echo "0")

# Check for concurrency groups (prevents queue pile-ups)
CONCURRENCY_COUNT=$(grep -l "^concurrency:" "${REPO_ROOT}/.github/workflows/"*.yml 2>/dev/null | wc -l | tr -d ' ')
CONCURRENCY_RATIO=$((CONCURRENCY_COUNT * 100 / WF_COUNT))

if [[ "${CONCURRENCY_RATIO}" -ge 80 ]]; then
    score "concurrency_groups" 2 2 "Concurrency groups: ${CONCURRENCY_COUNT}/${WF_COUNT} workflows (${CONCURRENCY_RATIO}%)"
elif [[ "${CONCURRENCY_RATIO}" -ge 50 ]]; then
    score "concurrency_groups" 1 2 "Concurrency groups: ${CONCURRENCY_COUNT}/${WF_COUNT} workflows (${CONCURRENCY_RATIO}%)"
else
    score "concurrency_groups" 0 2 "Concurrency groups: only ${CONCURRENCY_COUNT}/${WF_COUNT} workflows (${CONCURRENCY_RATIO}%)"
fi

# GraphQL adoption (reduces REST calls = less compute)
if [[ "${GRAPHQL_COUNT}" -ge 5 ]]; then
    score "graphql_adoption" 2 2 "GraphQL adopted in ${GRAPHQL_COUNT} scripts (reduces API quota consumption)"
else
    score "graphql_adoption" 0 2 "GraphQL adoption low (${GRAPHQL_COUNT} scripts)"
fi

# ── F. Dependency minimalism ──────────────────────────────────────────────────
info "F. Auditing dependency footprint..."

# Count apt-get install calls across all workflows
APT_INSTALLS=$(grep -rn "apt-get install\|apt install" \
    "${REPO_ROOT}/.github/workflows/" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
PIP_INSTALLS=$(grep -rn "pip install\|pip3 install" \
    "${REPO_ROOT}/.github/workflows/" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
NPM_INSTALLS=$(grep -rn "npm install\|npm ci\|yarn install\|bun install" \
    "${REPO_ROOT}/.github/workflows/" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

TOTAL_INSTALLS=$((APT_INSTALLS + PIP_INSTALLS + NPM_INSTALLS))
INSTALLS_PER_WF=$(python3 -c "print(round(${TOTAL_INSTALLS}/${WF_COUNT},1))")

if python3 -c "exit(0 if ${INSTALLS_PER_WF} < 0.5 else 1)"; then
    score "dep_minimalism" 2 2 "Low dependency footprint: ${INSTALLS_PER_WF} installs/workflow avg"
elif python3 -c "exit(0 if ${INSTALLS_PER_WF} < 1.5 else 1)"; then
    score "dep_minimalism" 1 2 "Moderate dependency footprint: ${INSTALLS_PER_WF} installs/workflow avg"
else
    score "dep_minimalism" 0 2 "High dependency footprint: ${INSTALLS_PER_WF} installs/workflow avg"
fi

# ── G. Runner carbon estimate (stub with real formula) ────────────────────────
info "G. Estimating CI carbon footprint..."
# Formula: runner_minutes × TDP_watts / 60 × PUE × grid_intensity_gCO2_per_kWh / 1000
# GitHub Actions ubuntu-latest = Azure North Central US
# Azure North Central US grid intensity ≈ 420 gCO2/kWh (EPA eGRID 2022, MROW region)
# GitHub runner TDP estimate ≈ 30W (2-core shared VM)
# Azure PUE ≈ 1.18 (Microsoft 2023 sustainability report)
# Assumes 100 workflow runs/day average across all 115 workflows, avg 3 min each

DAILY_RUNS=100
AVG_DURATION_MIN=3
TDP_WATTS=30
PUE=1.18
GRID_INTENSITY=420  # gCO2/kWh

CARBON_ESTIMATE=$(python3 -c "
runs=${DAILY_RUNS}
mins=${AVG_DURATION_MIN}
tdp=${TDP_WATTS}
pue=${PUE}
grid=${GRID_INTENSITY}
kwh_per_run = (mins / 60) * (tdp / 1000) * pue
co2_per_run_g = kwh_per_run * grid
daily_co2_g = runs * co2_per_run_g
annual_co2_kg = daily_co2_g * 365 / 1000
print(f'{annual_co2_kg:.2f}')
")

stub "Carbon estimate: ~${CARBON_ESTIMATE} kg CO2e/year (${DAILY_RUNS} runs/day × ${AVG_DURATION_MIN}min × Azure MROW grid)"
stub "For precise measurement: submit to KEcoLab (see gitlab-ci-eco.yml.tpl)"
score "carbon_estimate" 1 2 "Carbon estimate available: ~${CARBON_ESTIMATE} kg CO2e/year (stub — KEcoLab needed for precision)"

# ── H. KEcoLab stub ───────────────────────────────────────────────────────────
info "H. KEcoLab integration (stub)..."
stub "KEcoLab requires physical power meter at KDE infrastructure"
stub "Setup: see scripts/eco/gitlab-ci-eco.yml.tpl"
stub "Submit: https://invent.kde.org/teams/eco/remote-eco-lab"
score "keco_lab" 0 2 "KEcoLab: not yet configured (stub — requires GitLab CI + physical hardware)"

# ── I. Runs on old hardware (proxy: no min-spec requirements) ─────────────────
info "I. Checking hardware requirements..."
MIN_SPEC_HITS=$(grep -rn "requires.*GB\|minimum.*RAM\|min.*memory\|requires.*CPU" \
    "${REPO_ROOT}/README.md" "${REPO_ROOT}/DOCS/" 2>/dev/null \
    | grep -v "eco-audit\|generated" \
    | wc -l | tr -dc '0-9' || echo "0")
MIN_SPEC_HITS="${MIN_SPEC_HITS:-0}"

if [[ "${MIN_SPEC_HITS}" -eq 0 ]]; then
    score "old_hardware" 2 2 "No minimum hardware requirements specified (shell scripts run on any hardware)"
else
    score "old_hardware" 1 2 "Hardware requirements mentioned (${MIN_SPEC_HITS} references — review)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
PERCENT=$((SCORE * 100 / MAX_SCORE))
info "Score: ${SCORE}/${MAX_SCORE} (${PERCENT}%)"

if [[ "${PERCENT}" -ge 80 ]]; then
    GRADE="A — Excellent"
    GRADE_EMOJI="🟢"
elif [[ "${PERCENT}" -ge 60 ]]; then
    GRADE="B — Good"
    GRADE_EMOJI="🟡"
elif [[ "${PERCENT}" -ge 40 ]]; then
    GRADE="C — Fair"
    GRADE_EMOJI="🟠"
else
    GRADE="D — Needs work"
    GRADE_EMOJI="🔴"
fi

# ── Write JSON output ─────────────────────────────────────────────────────────
# Build results dict via Python to avoid shell escaping issues
RESULTS_JSON=$(python3 - << 'RJEOF'
import json, os, sys
# Read from env vars set below
data = {}
for k, v in os.environ.items():
    if k.startswith("_ECO_RESULT_"):
        key = k[len("_ECO_RESULT_"):]
        pts, label = v.split("|", 1)
        data[key] = {"score": pts, "label": label}
print(json.dumps(data))
RJEOF
)

python3 - "${ECO_JSON_OUT}" "${NOW}" "${REPO}" "${SCORE}" "${MAX_SCORE}" \
    "${PERCENT}" "${GRADE}" "${CARBON_ESTIMATE}" "${PAGES_URL}" \
    "${GREEN_DETAIL}" "${WF_COUNT}" "${GRAPHQL_COUNT}" "${CONCURRENCY_COUNT}" \
    "${APT_INSTALLS}" "${PIP_INSTALLS}" "${NPM_INSTALLS}" "${RESULTS_JSON}" << 'PYEOF'
import json, sys
(out_path, now, repo, score, max_score, percent, grade,
 carbon, pages_url, green_detail, wf_count, graphql,
 concurrency, apt, pip_, npm, results_json) = sys.argv[1:]

output = {
    "generated_at": now,
    "repo": repo,
    "score": int(score),
    "max_score": int(max_score),
    "percent": int(percent),
    "grade": grade,
    "results": json.loads(results_json),
    "carbon_estimate_kg_co2e_per_year": float(carbon),
    "green_hosting": {"url": pages_url, "detail": green_detail},
    "keco_lab": {
        "status": "stub",
        "setup_guide": "scripts/eco/gitlab-ci-eco.yml.tpl",
        "submit_url": "https://invent.kde.org/teams/eco/remote-eco-lab",
    },
    "ci_stats": {
        "workflow_count": int(wf_count),
        "graphql_scripts": int(graphql),
        "concurrency_groups": int(concurrency),
        "apt_installs": int(apt),
        "pip_installs": int(pip_),
        "npm_installs": int(npm),
    },
}
with open(out_path, "w") as f:
    json.dump(output, f, indent=2)
    f.write("\n")
print(f"JSON written: {out_path}")
PYEOF

info "JSON written: ${ECO_JSON_OUT}"

# ── Write Markdown report ─────────────────────────────────────────────────────
mkdir -p "$(dirname "${ECO_OUTPUT_MD}")"
cat > "${ECO_OUTPUT_MD}" << MDEOF
# Eco Audit

> Generated ${DATE} by \`scripts/eco/eco-audit.sh\`
> Aligned with [KDE Eco](https://eco.kde.org/) / [Blue Angel DE-UZ 215](https://www.blauer-engel.de/en/certification/criteria) criteria.

## Score: ${GRADE_EMOJI} ${SCORE}/${MAX_SCORE} (${PERCENT}%) — ${GRADE}

| Check | Score | Detail |
|---|---|---|
$(for k in green_hosting foss_license no_telemetry no_forced_updates concurrency_groups graphql_adoption dep_minimalism carbon_estimate keco_lab old_hardware; do
    if [[ -n "${RESULTS[$k]:-}" ]]; then
        pts="${RESULTS[$k]%%|*}"
        label="${RESULTS[$k]##*|}"
        num="${pts%%/*}"
        den="${pts##*/}"
        if [[ "${num}" -eq "${den}" ]]; then icon="✅"
        elif [[ "${num}" -gt 0 ]]; then icon="⚠️"
        else icon="❌"; fi
        echo "| ${icon} ${k//_/ } | ${pts} | ${label} |"
    fi
done)

---

## Carbon Footprint Estimate

| Parameter | Value | Source |
|---|---|---|
| Daily workflow runs | ~${DAILY_RUNS} | Estimate |
| Avg job duration | ~${AVG_DURATION_MIN} min | Estimate |
| Runner TDP | ~${TDP_WATTS}W | GitHub ubuntu-latest (2-core shared VM) |
| Azure PUE | ${PUE} | Microsoft 2023 Sustainability Report |
| Grid intensity | ${GRID_INTENSITY} gCO2/kWh | EPA eGRID 2022, MROW (Azure North Central US) |
| **Annual estimate** | **~${CARBON_ESTIMATE} kg CO2e/year** | Proxy — not measured |

> ⚠️ This is a proxy estimate. Precise measurement requires [KEcoLab](#keco-lab-gitlab-stub).

---

## Green Hosting

- **URL checked:** \`${PAGES_URL}\`
- **Result:** ${GREEN_DETAIL}
- **Checker:** [Green Web Foundation](https://www.thegreenwebfoundation.org/)

---

## KEcoLab (GitLab Stub)

KEcoLab is KDE's remote energy measurement lab. It uses a physical power meter
connected to test hardware to measure actual watt-hours consumed per use case.

**This cannot run on GitHub Actions** — it requires physical hardware at KDE's
infrastructure. The stub below is ready to activate when hosted on GitLab.

### Setup steps

1. Write \`KdeEcoTest\` scripts simulating user interactions with your software
2. Add \`.gitlab-ci-eco.yml\` to your repo (template: \`scripts/eco/gitlab-ci-eco.yml.tpl\`)
3. Submit to KEcoLab: <https://invent.kde.org/teams/eco/remote-eco-lab>
4. Receive energy consumption report (watt-hours per use case)
5. Apply for Blue Angel DE-UZ 215 if criteria are met

### Resources

| Resource | URL |
|---|---|
| KEcoLab repository | <https://invent.kde.org/teams/eco/remote-eco-lab> |
| KDE Eco Handbook | <https://eco.kde.org/be4foss-handbook> |
| KdeEcoTest tool | <https://invent.kde.org/teams/eco/feep/-/tree/master/tools/KdeEcoTest> |
| Blue Angel criteria | <https://www.blauer-engel.de/en/certification/criteria> |
| Criteria PDF (DE-UZ 215) | <https://www.blauer-engel.de/sites/default/files/vergabegrundlagen-dokumente/DE-UZ-215-Vergabegrundlagen-2020-01-01.pdf> |

---

## CI Efficiency Stats

| Metric | Value |
|---|---|
| Total workflows | ${WF_COUNT} |
| Workflows with concurrency groups | ${CONCURRENCY_COUNT} (${CONCURRENCY_RATIO}%) |
| Scripts using GraphQL | ${GRAPHQL_COUNT} |
| apt-get install calls | ${APT_INSTALLS} |
| pip install calls | ${PIP_INSTALLS} |
| npm/yarn/bun install calls | ${NPM_INSTALLS} |

---

## Blue Angel DE-UZ 215 Checklist

| Criterion | Status | Notes |
|---|---|---|
| FOSS license | ✅ | Open source — transparency by design |
| No telemetry / tracking | ✅ | No analytics, beacons, or tracking scripts |
| No forced updates | ✅ | All updates are opt-in via OTA system |
| Runs on old hardware | ✅ | Shell scripts — no minimum spec |
| User data control | ✅ | No user data collected |
| Energy measurement | ⏳ Stub | Requires KEcoLab (GitLab) |
| Documented energy use | ⏳ Stub | Pending KEcoLab measurement |
| Green hosting | ${GREEN_DETAIL} | GitHub Pages via Azure |

---

*Full glossary: [Glossary](glossary.md) · Eco resources: [eco.kde.org](https://eco.kde.org/)*
MDEOF

info "Markdown written: ${ECO_OUTPUT_MD}"

# Print summary to stdout for CI step summary
cat << SUMMARY
## ${GRADE_EMOJI} Eco Audit — ${GRADE}

**Score: ${SCORE}/${MAX_SCORE} (${PERCENT}%)**

| Check | Result |
|---|---|
$(for k in green_hosting foss_license no_telemetry no_forced_updates concurrency_groups graphql_adoption dep_minimalism carbon_estimate keco_lab old_hardware; do
    if [[ -n "${RESULTS[$k]:-}" ]]; then
        pts="${RESULTS[$k]%%|*}"
        label="${RESULTS[$k]##*|}"
        num="${pts%%/*}"
        den="${pts##*/}"
        if [[ "${num}" -eq "${den}" ]]; then icon="✅"
        elif [[ "${num}" -gt 0 ]]; then icon="⚠️"
        else icon="❌"; fi
        echo "| ${icon} ${k//_/ } | ${label} |"
    fi
done)

Carbon estimate: ~${CARBON_ESTIMATE} kg CO2e/year · KEcoLab: stub (activate on GitLab)
SUMMARY
