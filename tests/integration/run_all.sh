#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# run_all.sh - Run all integration tests and report results
#
# Artifacts written to tests/integration/results/:
#   junit.xml              - JUnit XML for GitLab test report widget
#   snapshot-status.json   - bdfs snapshot status -j output per workspace suite
#   summary.json           - overall pass/fail/skip counts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
FAILED_SUITES=()
JUNIT_CASES=""

mkdir -p "$RESULTS_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# emit_snapshot_status <btrfs_mount> <suite_name>
# Runs bdfs snapshot status -j and appends one JSON line to snapshot-status.json.
# Non-fatal: silently skipped when bdfs is absent or the mount does not exist.
emit_snapshot_status() {
    local mount="$1" suite="$2"
    command -v bdfs &>/dev/null || return 0
    [[ -d "$mount" ]] || return 0
    local json
    json=$(bdfs snapshot status --btrfs-mount "$mount" -j 2>/dev/null || true)
    [[ -n "$json" ]] || return 0
    printf '{"suite":"%s","timestamp":"%s","status":%s}\n' \
        "$suite" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$json" \
        >> "${RESULTS_DIR}/snapshot-status.json"
}

run_suite() {
    local script=$1
    local name
    name=$(basename "$script" .sh)

    echo ""
    echo -e "${BOLD}━━━ ${name} ━━━${NC}"

    local output rc=0 start_ts end_ts elapsed_s
    start_ts=$(date +%s%N)
    output=$(bash "$script" 2>&1) || rc=$?
    end_ts=$(date +%s%N)
    elapsed_s=$(awk "BEGIN{printf \"%.3f\", ($end_ts-$start_ts)/1000000000}")

    echo "$output"

    local pass fail skip
    pass=$(echo "$output" | grep -oP '\d+(?= passed)' | tail -1 || true); pass=${pass:-0}
    fail=$(echo "$output" | grep -oP '\d+(?= failed)' | tail -1 || true); fail=${fail:-0}
    skip=$(echo "$output" | grep -oP '\d+(?= skipped)' | tail -1 || true); skip=${skip:-0}

    TOTAL_PASS=$(( TOTAL_PASS + pass ))
    TOTAL_FAIL=$(( TOTAL_FAIL + fail ))
    TOTAL_SKIP=$(( TOTAL_SKIP + skip ))

    [[ $rc -ne 0 || $fail -gt 0 ]] && FAILED_SUITES+=("$name")

    # JUnit testcase
    local esc_name
    esc_name=$(xml_escape "$name")
    if [[ $rc -eq 0 && $fail -eq 0 ]]; then
        JUNIT_CASES+="    <testcase name=\"${esc_name}\" time=\"${elapsed_s}\">"
        [[ $skip -gt 0 ]] && JUNIT_CASES+="<skipped message=\"${skip} skipped\"/>"
        JUNIT_CASES+="</testcase>\n"
    else
        local tail_output
        tail_output=$(xml_escape "${output: -2000}")
        JUNIT_CASES+="    <testcase name=\"${esc_name}\" time=\"${elapsed_s}\">"
        JUNIT_CASES+="<failure message=\"${fail} failed (exit ${rc})\">${tail_output}</failure>"
        JUNIT_CASES+="</testcase>\n"
    fi

    # Snapshot status artifact for workspace/snapshot suites
    if [[ "$name" == *workspace* || "$name" == *snapshot* ]]; then
        for m in /tmp/bdfs_ws_* /tmp/bdfs_snap_*; do
            [[ -d "$m" ]] && emit_snapshot_status "$m" "$name" || true
        done
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo -e "${BOLD}BTRFS+DwarFS Framework Integration Tests${NC}"
echo "========================================="
echo "Date: $(date)"
echo "Kernel: $(uname -r)"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}error:${NC} Integration tests require root."
    exit 1
fi

rm -f "${RESULTS_DIR}/snapshot-status.json"

for suite in \
    "$SCRIPT_DIR/test_kernel_module.sh" \
    "$SCRIPT_DIR/test_dwarfs_partition.sh" \
    "$SCRIPT_DIR/test_btrfs_partition.sh" \
    "$SCRIPT_DIR/test_blend_layer.sh" \
    "$SCRIPT_DIR/test_snapshot_lifecycle.sh" \
    "$SCRIPT_DIR/test_workspace_hooks.sh" \
    "$SCRIPT_DIR/test_ipfs_pin.sh" \
    "$SCRIPT_DIR/test_workspace_health_check.sh"
do
    if [[ -f "$suite" ]]; then
        run_suite "$suite"
    else
        echo -e "${YELLOW}MISSING${NC} $suite"
    fi
done

# ── Artifacts ─────────────────────────────────────────────────────────────────

TOTAL=$(( TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP ))

# JUnit XML
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuites name=\"bdfs-integration\" tests=\"${TOTAL}\" failures=\"${TOTAL_FAIL}\" skipped=\"${TOTAL_SKIP}\">"
    echo "  <testsuite name=\"integration\" tests=\"${TOTAL}\" failures=\"${TOTAL_FAIL}\" skipped=\"${TOTAL_SKIP}\">"
    printf '%b' "$JUNIT_CASES"
    echo "  </testsuite>"
    echo "</testsuites>"
} > "${RESULTS_DIR}/junit.xml"

# Summary JSON
{
    local_failed=""
    for s in "${FAILED_SUITES[@]+"${FAILED_SUITES[@]}"}"; do
        local_failed+="\"$s\","
    done
    local_failed="${local_failed%,}"
    printf '{"timestamp":"%s","kernel":"%s","total":%d,"passed":%d,"failed":%d,"skipped":%d,"failed_suites":[%s]}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -r)" \
        "$TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP" \
        "$local_failed"
} > "${RESULTS_DIR}/summary.json"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Overall: ${TOTAL} tests${NC}"
echo -e "  ${GREEN}Passed:  ${TOTAL_PASS}${NC}"
echo -e "  ${RED}Failed:  ${TOTAL_FAIL}${NC}"
echo -e "  ${YELLOW}Skipped: ${TOTAL_SKIP}${NC}"
echo ""
echo "Artifacts: ${RESULTS_DIR}/"
echo "  junit.xml  summary.json$([ -f "${RESULTS_DIR}/snapshot-status.json" ] && echo "  snapshot-status.json" || true)"

if [[ ${#FAILED_SUITES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Failed suites:${NC}"
    for s in "${FAILED_SUITES[@]}"; do echo "  - $s"; done
    exit 1
else
    echo ""
    echo -e "${GREEN}All suites passed.${NC}"
    exit 0
fi
