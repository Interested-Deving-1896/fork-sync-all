#!/usr/bin/env bash
#
# ota-reconcile.sh
#
# Hybrid fallback and drift-detection layer for mirror-chain consumer repos.
# Runs weekly (via ota-reconcile.yml) and autonomously selects the best
# recovery path per repo at runtime:
#
#   Path A — Version stamp only (repo is current, just update .ota/version)
#   Path B — Drift reconcile (files differ, open a PR with the delta)
#   Path C — Quota fallback (sync-template.sh left this repo incomplete)
#
# Detection order per repo:
#   1. Read .ota/version SHA via raw.githubusercontent (no quota cost)
#   2. Compare against current FSA HEAD SHA
#   3. Check for an existing open reconcile PR (avoid duplicates)
#   4. Check OTA_SYNC_INCOMPLETE Actions variable (quota failure indicator)
#   5. Run ota-payload-build.sh --full --dry-run to confirm actual file delta
#
# Required env:
#   GH_TOKEN        GitHub PAT with repo read + PR write + variables write
#   GITHUB_OWNER    Org containing consumer repos (Interested-Deving-1896)
#   FSA_SHA         Current fork-sync-all HEAD SHA (written to .ota/version)
#
# Optional env:
#   CONSUMERS_FILE    Path to config/template-consumers.yml
#   BLOCKLIST_FILE    Path to config/ota-blocklist.yml
#   MANIFEST_FILE     Path to config/template-manifest.yml
#   DRY_RUN           "true" to skip writes and PR creation
#   REPO_FILTER       Substring filter on repo name
#   FORCE_PATH        Override path selection: A | B | C
#   PROFILE_FILTER    Only process repos with this template profile
#   OTA_VERSION       Version tag for PR branch names (default: reconcile)
#   BUDGET_MINUTES    Max runtime in minutes (default: 50)
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${FSA_SHA:?FSA_SHA is required}"

CONSUMERS_FILE="${CONSUMERS_FILE:-config/template-consumers.yml}"
BLOCKLIST_FILE="${BLOCKLIST_FILE:-config/ota-blocklist.yml}"
MANIFEST_FILE="${MANIFEST_FILE:-config/template-manifest.yml}"
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
FORCE_PATH="${FORCE_PATH:-}"
PROFILE_FILTER="${PROFILE_FILTER:-}"
OTA_VERSION="${OTA_VERSION:-reconcile}"
BUDGET_MINUTES="${BUDGET_MINUTES:-50}"
PAYLOAD_BUILD_SCRIPT="${PAYLOAD_BUILD_SCRIPT:-scripts/ota-payload-build.sh}"
API="${API:-https://api.github.com}"
RAW="${RAW:-https://raw.githubusercontent.com}"

# ── helpers ───────────────────────────────────────────────────────────────────

info() { echo "[ota-reconcile] $*" >&2; }
warn() { echo "[ota-reconcile] WARN: $*" >&2; }
die()  { echo "[ota-reconcile] ERROR: $*" >&2; exit 1; }

gh_api() {
  local method="$1" url="$2"; shift 2
  curl -sf -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url" 2>/dev/null || echo "{}"
}

gh_get() {
  gh_api GET "$1"
}

# Budget: wall-clock deadline
DEADLINE=$(( $(date +%s) + BUDGET_MINUTES * 60 ))
budget_ok() { (( $(date +%s) < DEADLINE )); }

# ── read consumers ────────────────────────────────────────────────────────────

read_consumers() {
  python3 - "$CONSUMERS_FILE" "$PROFILE_FILTER" <<'PYEOF'
import sys, yaml

consumers_file = sys.argv[1]
profile_filter = sys.argv[2]

with open(consumers_file) as f:
    data = yaml.safe_load(f) or {}

consumers = data.get("consumers", []) or []
for c in consumers:
    if not isinstance(c, dict):
        continue
    name = c.get("name", "")
    profile = c.get("profile", "full")
    disabled = c.get("disabled", False)
    if disabled or not name:
        continue
    if profile_filter and profile != profile_filter:
        continue
    print(f"{name}\t{profile}")
PYEOF
}

# ── reconcile_eligible check ──────────────────────────────────────────────────

is_reconcile_eligible() {
  local profile="$1"
  python3 - "$BLOCKLIST_FILE" "$profile" <<'PYEOF'
import sys, yaml

blocklist_file = sys.argv[1]
profile = sys.argv[2]

with open(blocklist_file) as f:
    data = yaml.safe_load(f) or {}

eligible = data.get("reconcile_eligible_profiles", ["full", "mirror", "infra-core", "standalone"])
sys.exit(0 if profile in eligible else 1)
PYEOF
}

# ── per-repo .ota/config.yml checks ──────────────────────────────────────────

repo_reconcile_enabled() {
  local repo="$1"
  # Returns 0 (enabled) unless reconcile: false is set in .ota/config.yml
  local content
  content=$(curl -sf \
    "${RAW}/${repo}/main/.ota/config.yml" \
    -H "Authorization: token ${GH_TOKEN}" 2>/dev/null || true)
  if echo "$content" | grep -q "^reconcile: false"; then
    return 1
  fi
  return 0
}

repo_max_path() {
  local repo="$1"
  local content
  content=$(curl -sf \
    "${RAW}/${repo}/main/.ota/config.yml" \
    -H "Authorization: token ${GH_TOKEN}" 2>/dev/null || true)
  echo "$content" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('reconcile_max_path:'):
        val = line.split(':', 1)[1].strip().strip('\"')
        print(val)
        sys.exit(0)
print('C')
" 2>/dev/null || echo "C"
}

# ── detection checks ──────────────────────────────────────────────────────────

# Check 1+2: read .ota/version and compare SHA
# Returns: "current" | "behind" | "missing"
check_version_stamp() {
  local repo="$1"
  local content
  content=$(curl -sf \
    "${RAW}/${repo}/main/.ota/version" \
    -H "Authorization: token ${GH_TOKEN}" 2>/dev/null || true)

  if [[ -z "$content" ]]; then
    echo "missing"
    return
  fi

  local stamped_sha
  stamped_sha=$(echo "$content" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('fsa_sha:'):
        print(line.split(':', 1)[1].strip())
        sys.exit(0)
" 2>/dev/null || true)

  if [[ -z "$stamped_sha" ]]; then
    echo "missing"
  elif [[ "$stamped_sha" == "$FSA_SHA" ]]; then
    echo "current"
  else
    echo "behind"
  fi
}

# Check 3: open reconcile PR exists?
check_open_pr() {
  local repo="$1"
  local prs
  prs=$(gh_get "${API}/repos/${repo}/pulls?state=open&per_page=50")
  echo "$prs" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
if not isinstance(prs, list):
    sys.exit(1)
for pr in prs:
    branch = pr.get('head', {}).get('ref', '')
    if branch.startswith('ota/reconcile') or branch.startswith('ota/quota-recovery'):
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Check 4: OTA_SYNC_INCOMPLETE Actions variable
check_sync_incomplete() {
  local repo="$1"
  local result
  result=$(gh_get "${API}/repos/${repo}/actions/variables/OTA_SYNC_INCOMPLETE")
  local val
  val=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('value', 'false'))
" 2>/dev/null || echo "false")
  [[ "$val" == "true" ]]
}

# Clear OTA_SYNC_INCOMPLETE after handling
clear_sync_incomplete() {
  local repo="$1"
  [[ "$DRY_RUN" == "true" ]] && return
  curl -sf -X DELETE \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${repo}/actions/variables/OTA_SYNC_INCOMPLETE" \
    >/dev/null 2>&1 || true
}

# ── path selector ─────────────────────────────────────────────────────────────

select_path() {
  local repo="$1"
  local repo_name="${repo##*/}"

  # Honour explicit override
  if [[ -n "$FORCE_PATH" ]]; then
    echo "$FORCE_PATH"
    return
  fi

  # Honour per-repo max_path cap
  local max_path
  max_path=$(repo_max_path "$repo")

  # Check 1+2: version stamp
  local stamp_status
  stamp_status=$(check_version_stamp "$repo")
  info "  stamp: ${stamp_status}"

  if [[ "$stamp_status" == "current" ]]; then
    echo "A"
    return
  fi

  # Stamp missing or behind — check for in-flight PR
  if check_open_pr "$repo"; then
    info "  open reconcile PR found — skipping"
    echo "SKIP"
    return
  fi

  # Check 4: quota failure?
  if check_sync_incomplete "$repo"; then
    info "  OTA_SYNC_INCOMPLETE=true — quota fallback"
    if [[ "$max_path" == "A" ]]; then
      echo "A"
    else
      echo "C"
    fi
    return
  fi

  # Default: drift reconcile
  if [[ "$max_path" == "A" ]]; then
    echo "A"
  else
    echo "B"
  fi
}

# ── path A: write version stamp ───────────────────────────────────────────────

do_path_a() {
  local repo="$1" path_label="${2:-A}"
  local repo_name="${repo##*/}"

  local stamp
  stamp=$(printf 'fsa_sha: %s\nfsa_ref: main\nstamped_at: %s\nreconcile_path: %s\n' \
    "$FSA_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path_label")

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY: would write .ota/version to ${repo}"
    return 0
  fi

  # Get current file SHA if it exists (needed for update)
  local existing_sha=""
  local existing
  existing=$(gh_get "${API}/repos/${repo}/contents/.ota/version")
  existing_sha=$(echo "$existing" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)

  local payload
  payload=$(python3 -c "
import json, base64, sys
content = base64.b64encode(sys.stdin.read().encode()).decode()
d = {'message': 'chore: update .ota/version [skip ci]', 'content': content}
sha = '$existing_sha'
if sha:
    d['sha'] = sha
print(json.dumps(d))
" <<< "$stamp")

  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${API}/repos/${repo}/contents/.ota/version" \
    -d "$payload" 2>/dev/null) || http_code="000"

  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    info "  .ota/version written (path ${path_label})"
    return 0
  else
    warn "  Failed to write .ota/version to ${repo} (HTTP ${http_code})"
    return 1
  fi
}

# ── path B/C: drift reconcile via ota-payload-build.sh ───────────────────────

do_path_bc() {
  local repo="$1" path_label="$2"
  local repo_name="${repo##*/}"

  # Build payload
  local payload_dir
  payload_dir=$(mktemp -d)
  trap 'rm -rf "$payload_dir"' RETURN

  local rc=0
  TARGET_REPO="$repo" \
  PAYLOAD_DIR="$payload_dir" \
  MANIFEST_FILE="$MANIFEST_FILE" \
  GH_TOKEN="$GH_TOKEN" \
  DRY_RUN="false" \
    bash "$PAYLOAD_BUILD_SCRIPT" --full 2>&1 | sed 's/^/    /' >&2 || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    warn "  Payload build failed (exit ${rc})"
    return 1
  fi

  # Check 5: confirm actual delta
  if [[ ! -s "${payload_dir}/.ota-changed-files" ]]; then
    info "  No file delta after payload build — writing stamp only"
    do_path_a "$repo" "$path_label"
    return $?
  fi

  local changed_count
  changed_count=$(wc -l < "${payload_dir}/.ota-changed-files")
  info "  ${changed_count} files to update (path ${path_label})"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY: would open PR against ${repo} (path ${path_label}, ${changed_count} files)"
    return 0
  fi

  # Clone target, apply payload, push branch, open PR
  local clone_dir
  clone_dir=$(mktemp -d)
  trap 'rm -rf "$clone_dir"' RETURN

  local clone_url="https://x-access-token:${GH_TOKEN}@github.com/${repo}.git"
  if ! git clone --quiet --depth=1 "$clone_url" "${clone_dir}/repo" 2>/dev/null; then
    warn "  Failed to clone ${repo}"
    return 1
  fi

  local default_branch
  default_branch=$(gh_get "${API}/repos/${repo}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

  pushd "${clone_dir}/repo" >/dev/null

  local branch_suffix
  if [[ "$path_label" == "C" ]]; then
    branch_suffix="quota-recovery-${FSA_SHA:0:8}"
  else
    branch_suffix="${OTA_VERSION}-${FSA_SHA:0:8}"
  fi
  local ota_branch="ota/reconcile-${branch_suffix}"

  git checkout -b "$ota_branch" 2>/dev/null

  # Apply payload + write version stamp
  while IFS= read -r changed_file; do
    [[ "$changed_file" == ".ota-changed-files" ]] && continue
    local dest_dir
    dest_dir="$(dirname "$changed_file")"
    mkdir -p "$dest_dir"
    cp "${payload_dir}/${changed_file}" "$changed_file"
    git add "$changed_file"
  done < "${payload_dir}/.ota-changed-files"

  # Write .ota/version into the branch
  mkdir -p .ota
  printf 'fsa_sha: %s\nfsa_ref: main\nstamped_at: %s\nreconcile_path: %s\n' \
    "$FSA_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path_label" > .ota/version
  git add .ota/version

  if git diff --cached --quiet; then
    info "  No staged changes — skipping PR"
    popd >/dev/null
    return 0
  fi

  local commit_msg="chore: OTA reconcile (path ${path_label}) — ${FSA_SHA:0:8}"
  if [[ "$path_label" == "C" ]]; then
    commit_msg="chore: OTA quota-recovery reconcile — ${FSA_SHA:0:8}"
  fi

  git -c user.name="ota-bot" -c user.email="ota@fork-sync-all" \
    commit -m "$commit_msg

Automated reconcile from fork-sync-all ota-reconcile.sh.
Path: ${path_label} | FSA SHA: ${FSA_SHA}
Files changed: ${changed_count}

Co-authored-by: Ona <no-reply@ona.com>" 2>/dev/null

  if ! git push --quiet origin "$ota_branch" 2>/dev/null; then
    warn "  Failed to push ${ota_branch} to ${repo}"
    popd >/dev/null
    return 1
  fi

  popd >/dev/null

  # Open PR
  local pr_title pr_label_note
  if [[ "$path_label" == "C" ]]; then
    pr_title="chore: OTA quota-recovery reconcile — ${FSA_SHA:0:8}"
    pr_label_note=" This PR was triggered by a detected quota-exhaustion gap in the last template sync run."
  else
    pr_title="chore: OTA drift reconcile — ${FSA_SHA:0:8}"
    pr_label_note=""
  fi

  local pr_body
  pr_body=$(printf \
'## OTA Reconcile (Path %s)

This PR was opened automatically by [fork-sync-all ota-reconcile.sh](https://github.com/Interested-Deving-1896/fork-sync-all).%s

**FSA SHA:** `%s`
**Files changed (%s):**
```
%s
```

To opt out of future reconcile runs, set `reconcile: false` in `.ota/config.yml`.' \
    "$path_label" "$pr_label_note" "$FSA_SHA" "$changed_count" \
    "$(grep -v '^\.ota-changed-files$' "${payload_dir}/.ota-changed-files" || true)")

  local pr_result
  pr_result=$(curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${API}/repos/${repo}/pulls" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
  'title': sys.argv[1],
  'head':  sys.argv[2],
  'base':  sys.argv[3],
  'body':  sys.stdin.read()
}))" "$pr_title" "$ota_branch" "$default_branch" <<< "$pr_body")" 2>/dev/null || echo "{}")

  local pr_url
  pr_url=$(echo "$pr_result" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || true)

  if [[ -n "$pr_url" ]]; then
    info "  PR opened: ${pr_url}"
    # Clear quota-failure indicator now that we've handled it
    [[ "$path_label" == "C" ]] && clear_sync_incomplete "$repo"
    return 0
  else
    local err
    err=$(echo "$pr_result" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null || true)
    warn "  PR creation failed: ${err}"
    return 1
  fi
}

# ── main loop ─────────────────────────────────────────────────────────────────

info "OTA Reconcile starting"
info "  FSA SHA:    ${FSA_SHA:0:12}..."
info "  Owner:      ${GITHUB_OWNER}"
info "  Dry run:    ${DRY_RUN}"
info "  Force path: ${FORCE_PATH:-auto}"
echo "" >&2

count_a=0; count_b=0; count_c=0; count_skip=0; count_fail=0
selected_path=""
local_repo=""

declare -a pr_b_list=() pr_c_list=()

while IFS=$'\t' read -r repo_name profile; do
  [[ -z "$repo_name" ]] && continue

  if [[ -n "$REPO_FILTER" && "$repo_name" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  if ! budget_ok; then
    warn "Budget exhausted — stopping early"
    break
  fi

  local_repo="${GITHUB_OWNER}/${repo_name}"
  info "──────────────────────────────────────────"
  info "Repo: ${local_repo}  profile=${profile}"

  # Profile eligibility
  if ! is_reconcile_eligible "$profile"; then
    info "  Profile '${profile}' not in reconcile_eligible_profiles — skipping"
    (( count_skip++ )) || true
    continue
  fi

  # Per-repo opt-out
  if ! repo_reconcile_enabled "$local_repo"; then
    info "  reconcile: false in .ota/config.yml — skipping"
    (( count_skip++ )) || true
    continue
  fi

  # Select path
  selected_path=$(select_path "$local_repo")

  if [[ "$selected_path" == "SKIP" ]]; then
    (( count_skip++ )) || true
    continue
  fi

  info "  Selected path: ${selected_path}"

  case "$selected_path" in
    A)
      if do_path_a "$local_repo" "A"; then
        (( count_a++ )) || true
      else
        (( count_fail++ )) || true
      fi
      ;;
    B)
      if do_path_bc "$local_repo" "B"; then
        (( count_b++ )) || true
        pr_b_list+=("$local_repo")
      else
        (( count_fail++ )) || true
      fi
      ;;
    C)
      if do_path_bc "$local_repo" "C"; then
        (( count_c++ )) || true
        pr_c_list+=("$local_repo")
      else
        (( count_fail++ )) || true
      fi
      ;;
    *)
      warn "  Unknown path '${selected_path}' — skipping"
      (( count_skip++ )) || true
      ;;
  esac

  echo "" >&2
done < <(read_consumers)

# ── summary ───────────────────────────────────────────────────────────────────

echo "" >&2
info "========================================"
info "  OTA Reconcile complete"
info "  Path A (stamp):  ${count_a}"
info "  Path B (drift):  ${count_b}"
info "  Path C (quota):  ${count_c}"
info "  Skipped:         ${count_skip}"
info "  Failed:          ${count_fail}"
info "========================================"

# Write GitHub Actions step summary if available
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## OTA Reconcile — \`${FSA_SHA:0:12}\`"
    echo ""
    echo "| | Count |"
    echo "|---|---|"
    echo "| Path A (stamp only) | ${count_a} |"
    echo "| Path B (drift PR) | ${count_b} |"
    echo "| Path C (quota-recovery PR) | ${count_c} |"
    echo "| Skipped | ${count_skip} |"
    echo "| Failed | ${count_fail} |"
    if [[ ${#pr_b_list[@]} -gt 0 ]]; then
      echo ""
      echo "### Path B PRs"
      for r in "${pr_b_list[@]}"; do echo "- \`${r}\`"; done
    fi
    if [[ ${#pr_c_list[@]} -gt 0 ]]; then
      echo ""
      echo "### Path C PRs (quota-recovery)"
      for r in "${pr_c_list[@]}"; do echo "- \`${r}\`"; done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

[[ "$count_fail" -gt 0 ]] && exit 1
exit 0
