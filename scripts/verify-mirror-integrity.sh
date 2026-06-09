#!/usr/bin/env bash
#
# verify-mirror-integrity.sh
#
# Compares default-branch HEAD SHAs between a source org and a destination org
# for all OSP-bound repos. Reports mismatches as warnings. Does not fail by
# default — use BLOCK_ON_MISMATCH=true to make mismatches a hard failure.
#
# Supports three mirror pairs:
#   id-1896-to-osp    — Interested-Deving-1896 → OpenOS-Project-OSP
#   osp-to-ooc        — OpenOS-Project-OSP → OpenOS-Project-Ecosystem-OOC
#   osp-to-gitlab     — OpenOS-Project-OSP → gitlab.com/openos-project (uses GitLab API)
#
# Required env vars:
#   GH_TOKEN           — PAT with repo read scope
#   MIRROR_PAIR        — one of: id-1896-to-osp | osp-to-ooc | osp-to-gitlab
#
# Optional env vars:
#   GITLAB_TOKEN       — required only for osp-to-gitlab pair
#   REPO_FILTER        — substring filter on repo name (default: all)
#   BLOCK_ON_MISMATCH  — "true" to exit 1 on any mismatch (default: false)
#   BUDGET_MINUTES     — time budget in minutes (default: 30)
#   MIN_QUOTA          — skip if quota below this (default: 400)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${MIRROR_PAIR:?MIRROR_PAIR is required (id-1896-to-osp|osp-to-ooc|osp-to-gitlab)}"

REPO_FILTER="${REPO_FILTER:-}"
BLOCK_ON_MISMATCH="${BLOCK_ON_MISMATCH:-false}"
MIN_QUOTA="${MIN_QUOTA:-400}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"

budget_init

# ── Logging ───────────────────────────────────────────────────────────────────
info()  { echo "[verify-mirror-integrity] $*" >&2; }
warn()  { echo "[verify-mirror-integrity] ⚠️  $*" >&2; }
ok()    { echo "[verify-mirror-integrity] ✓ $*" >&2; }
fail()  { echo "[verify-mirror-integrity] ✗ $*" >&2; }

# ── Validate MIRROR_PAIR ──────────────────────────────────────────────────────
case "$MIRROR_PAIR" in
  id-1896-to-osp|osp-to-ooc|osp-to-gitlab) ;;
  *)
    fail "Unknown MIRROR_PAIR '${MIRROR_PAIR}'. Must be one of: id-1896-to-osp, osp-to-ooc, osp-to-gitlab"
    exit 1
    ;;
esac

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota_remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo 0)

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — skipping integrity check."
  exit 0
fi
info "Quota: ${_quota_remaining} remaining"

# ── Load OSP-bound repo list ──────────────────────────────────────────────────
CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"
if [[ ! -f "$CONFIG" ]]; then
  warn "config/gitlab-subgroups.yml not found — skipping."
  exit 0
fi

mapfile -t OSP_REPOS < <(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys
data = yaml.safe_load(open(sys.argv[1]))
repos = []
for sg in (data.get("subgroups") or {}).values():
    repos.extend(sg.get("repos") or [])
for r in sorted(set(repos)):
    print(r)
PYEOF
)

info "OSP-bound repos to verify: ${#OSP_REPOS[@]} (pair: ${MIRROR_PAIR})"

# ── Resolve source/dest orgs ──────────────────────────────────────────────────
case "$MIRROR_PAIR" in
  id-1896-to-osp)
    SRC_ORG="Interested-Deving-1896"
    DST_ORG="OpenOS-Project-OSP"
    DST_BACKEND="github"
    ;;
  osp-to-ooc)
    SRC_ORG="OpenOS-Project-OSP"
    DST_ORG="OpenOS-Project-Ecosystem-OOC"
    DST_BACKEND="github"
    ;;
  osp-to-gitlab)
    SRC_ORG="OpenOS-Project-OSP"
    DST_ORG="openos-project"
    DST_BACKEND="gitlab"
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
      warn "GITLAB_TOKEN not set — skipping GitLab integrity check."
      exit 0
    fi
    ;;
esac

# ── SHA lookup helpers ────────────────────────────────────────────────────────

# Returns HEAD SHA for a GitHub repo's default branch, or empty string on error.
github_head_sha() {
  local org="$1" repo="$2"
  gh_get "https://api.github.com/repos/${org}/${repo}/commits/HEAD" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" \
    2>/dev/null || echo ""
}

# Returns HEAD SHA for a GitLab project's default branch, or empty string on error.
# Uses the subgroup path from config to build the full project path.
gitlab_head_sha() {
  local repo="$1"
  local gl_path
  gl_path=$(python3 - "$repo" "$CONFIG" <<'PYEOF'
import yaml, sys
repo = sys.argv[1]
config_path = sys.argv[2]
data = yaml.safe_load(open(config_path))
subgroups = data.get("subgroups", {}) or {}
default_sg = data.get("default_subgroup", "ops")
for sg_name, sg in subgroups.items():
    if repo in (sg.get("repos") or []):
        path = sg.get("path") or f"openos-project/{sg_name}"
        print(f"{path}/{repo}")
        sys.exit(0)
# fallback
print(f"openos-project/{default_sg}/{repo}")
PYEOF
)

  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],''))" "$gl_path")

  curl -sf \
    -H "Authorization: Bearer ${GITLAB_TOKEN}" \
    "https://gitlab.com/api/v4/projects/${encoded_path}/repository/commits?per_page=1" \
    2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" \
    2>/dev/null || echo ""
}

# ── Compare SHAs ──────────────────────────────────────────────────────────────
MISMATCH_COUNT=0
MISSING_COUNT=0
OK_COUNT=0
declare -a MISMATCHES=()

for repo in "${OSP_REPOS[@]}"; do
  budget_check "$repo" || break
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue

  src_sha=$(github_head_sha "$SRC_ORG" "$repo")
  if [[ -z "$src_sha" ]]; then
    warn "  SKIP: ${SRC_ORG}/${repo} — could not resolve source SHA"
    continue
  fi

  if [[ "$DST_BACKEND" == "github" ]]; then
    dst_sha=$(github_head_sha "$DST_ORG" "$repo")
  else
    dst_sha=$(gitlab_head_sha "$repo")
  fi

  if [[ -z "$dst_sha" ]]; then
    warn "  MISSING: ${repo} not found in ${DST_ORG}"
    MISMATCHES+=("MISSING:${repo}")
    (( MISSING_COUNT++ )) || true
    continue
  fi

  # Compare first 12 chars (short SHA) — GitLab may return full SHA, GitHub too
  src_short="${src_sha:0:12}"
  dst_short="${dst_sha:0:12}"

  if [[ "$src_short" == "$dst_short" ]]; then
    ok "  IN SYNC: ${repo} (${src_short})"
    (( OK_COUNT++ )) || true
  else
    warn "  MISMATCH: ${repo} — src=${src_short} dst=${dst_short}"
    MISMATCHES+=("MISMATCH:${repo}:src=${src_short}:dst=${dst_short}")
    (( MISMATCH_COUNT++ )) || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_ISSUES=$(( MISMATCH_COUNT + MISSING_COUNT ))

info ""
info "Integrity check complete (${MIRROR_PAIR}):"
info "  In sync:  ${OK_COUNT}"
info "  Mismatch: ${MISMATCH_COUNT}"
info "  Missing:  ${MISSING_COUNT}"

if [[ ${#MISMATCHES[@]} -gt 0 ]]; then
  info ""
  info "Issues:"
  for m in "${MISMATCHES[@]}"; do
    warn "  ${m}"
  done
fi

# Emit structured output for GitHub Actions step summary
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Mirror Integrity: ${MIRROR_PAIR}"
    echo ""
    echo "| Metric | Count |"
    echo "|--------|-------|"
    echo "| ✅ In sync | ${OK_COUNT} |"
    echo "| ⚠️ Mismatch | ${MISMATCH_COUNT} |"
    echo "| ❌ Missing | ${MISSING_COUNT} |"
    if [[ ${#MISMATCHES[@]} -gt 0 ]]; then
      echo ""
      echo "### Issues"
      echo '```'
      for m in "${MISMATCHES[@]}"; do echo "$m"; done
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$BLOCK_ON_MISMATCH" == "true" && "$TOTAL_ISSUES" -gt 0 ]]; then
  fail "Blocking: ${TOTAL_ISSUES} integrity issue(s) found in ${MIRROR_PAIR}."
  exit 1
fi

exit 0
