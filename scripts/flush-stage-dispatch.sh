#!/usr/bin/env bash
# Resolve a stage through the safety contract, then dispatch and await it.

set -uo pipefail

WORKFLOW="${1:?workflow file required}"
TIMEOUT_MIN="${2:-90}"
LIVE_INPUTS="${3-}"
[[ -n "$LIVE_INPUTS" ]] || LIVE_INPUTS='{}'
MODE="${FLUSH_EXECUTION_MODE:-live}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="${FLUSH_STAGE_CONTRACT:-${SCRIPT_DIR}/../config/flush-stage-contracts.yml}"
CURRENT_REPOSITORY="${REPO:-${GITHUB_REPOSITORY:-}}"

log() { echo "[flush-stage] $*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

[[ "$MODE" == "live" || "$MODE" == "rehearsal" ]] \
  || fail "FLUSH_EXECUTION_MODE must be live or rehearsal"

resolved=$(python3 "${SCRIPT_DIR}/validate-flush-stage-contracts.py" \
  --contract "$CONTRACT" \
  --resolve "$WORKFLOW" \
  --mode "$MODE" \
  --live-inputs "$LIVE_INPUTS" \
  --current-repository "$CURRENT_REPOSITORY") || exit $?

target_repo=$(python3 -c "import json,sys; print(json.load(sys.stdin)['repository'])" <<<"$resolved") \
  || fail "contract did not return a repository"
target_workflow=$(python3 -c "import json,sys; print(json.load(sys.stdin)['workflow'])" <<<"$resolved") \
  || fail "contract did not return a workflow"
inputs=$(python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['inputs'],separators=(',',':')))" <<<"$resolved") \
  || fail "contract did not return inputs"
capacity_slots=$(python3 -c "import json,sys; print(json.load(sys.stdin)['capacity_slots'])" <<<"$resolved") \
  || fail "contract did not return capacity_slots"

log "mode=${MODE} workflow=${target_workflow} repository=${target_repo} capacity_slots=${capacity_slots}"
REPO="$target_repo" DISPATCH_CAPACITY_SLOTS="$capacity_slots" \
  bash "${SCRIPT_DIR}/dispatch-and-wait.sh" "$target_workflow" "$TIMEOUT_MIN" "$inputs"
