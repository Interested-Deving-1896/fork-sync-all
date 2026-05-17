#!/usr/bin/env bash
#
# For every repo present on both UPSTREAM_OWNER and OSP_ORG, does a
# bare clone of the upstream and git push --mirror into OSP, syncing
# all branches, tags, and refs exactly.
#
# Repos that exist only in OSP (org-native, not mirrored) are skipped
# automatically — they won't be found on UPSTREAM_OWNER.
#
# Requires: GH_TOKEN (repo + admin:org + workflow scopes, write access
#           to OSP_ORG and read access to UPSTREAM_OWNER),
#           UPSTREAM_OWNER, OSP_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"

# Optional filters / flags (from workflow_dispatch inputs)
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
FORCE="${FORCE:-false}"

[[ "$DRY_RUN" == "true" ]] && echo "Dry run — no pushes will occur."
[[ "$FORCE"   == "true" ]] && echo "Force mode — CI gate bypassed for all repos."
[[ -n "$REPO_FILTER"    ]] && echo "Repo filter: '${REPO_FILTER}'"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"
PER_PAGE=100

# Repos with custom setups that must never be touched
EXCLUDED_REPOS=(
  "fork-sync-all"
  "org-mirror"
  "talos-incus"
)

# Repos that bypass the CI gate — their CI requires private infrastructure
# (e.g. private BuildKit clusters, Slack webhooks) that will never pass in
# the GitHub Actions environment. They are still mirrored; only the gate is skipped.
NO_GATE_REPOS=(
  "talos"
)

synced=0
failed=0
skipped=0
gated=0

# ── helpers ────────────────────────────────────────────────────────────────

is_excluded() {
  local repo="$1"
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$excluded" ]] && return 0
  done
  return 1
}

is_no_gate() {
  local repo="$1"
  for ng in "${NO_GATE_REPOS[@]}"; do
    [[ "$repo" == "$ng" ]] && return 0
  done
  return 1
}

api_get() {
  curl --disable --silent \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "$@"
}

sanitize() {
  sed "s/${GH_TOKEN}/***TOKEN***/g"
}

get_osp_repos() {
  local page=1
  while true; do
    local result count
    result=$(api_get "${API}/orgs/${OSP_ORG}/repos?type=all&per_page=${PER_PAGE}&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null) || break
    [[ -z "$count" || "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name' 2>/dev/null
    (( page++ ))
  done
}

mirror_repo() {
  local name="$1"
  local tmpdir clonedir
  tmpdir=$(mktemp -d)
  clonedir="${tmpdir}/${name}.git"

  local upstream_url target_url
  upstream_url="https://x-access-token:${GH_TOKEN}@github.com/${UPSTREAM_OWNER}/${name}.git"
  target_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${name}.git"

  # Bare clone from upstream
  if ! git clone --bare "$upstream_url" "$clonedir" 2>&1 | sanitize; then
    echo "  failed: could not clone ${UPSTREAM_OWNER}/${name}"
    rm -rf "$tmpdir"
    return 1
  fi

  cd "$clonedir" || return 1

  local attempt=0 push_ok=false push_output push_exit sanitized
  while (( attempt < 3 )); do
    push_output=$(git push --mirror "$target_url" 2>&1)
    push_exit=$?
    sanitized=$(echo "$push_output" | sanitize)
    echo "$sanitized"

    if [[ "$push_exit" -eq 0 ]]; then
      # git push itself succeeded — done
      push_ok=true
      break
    fi

    # git push failed — inspect why before deciding whether to retry
    if echo "$push_output" | grep -q "without \`workflow\` scope"; then
      echo "  ERROR: GH_TOKEN needs the 'workflow' scope to push repos containing .github/workflows/"
      break  # retrying won't help
    fi

    if echo "$push_output" | grep -q "remote rejected"; then
      # Remote rejection (e.g. protected branch) — retrying won't help
      echo "  ERROR: push rejected by remote"
      break
    fi

    # Transient error (network, auth timeout, etc.) — retry with back-off
    (( attempt++ ))
    if (( attempt < 3 )); then
      echo "  push attempt ${attempt} failed, retrying in 5s..."
      sleep 5
    fi
  done

  cd /
  rm -rf "$tmpdir"

  if $push_ok; then return 0; fi
  echo "  failed: could not push to ${OSP_ORG}/${name}"
  return 1
}

# ── main ───────────────────────────────────────────────────────────────────

echo "Validating token..."
if ! api_get "${API}/user" | jq -e '.login' >/dev/null 2>&1; then
  echo "ERROR: GH_TOKEN is invalid or lacks required permissions."
  exit 1
fi
echo "Token OK."
echo ""

echo "Fetching repos from ${OSP_ORG}..."
mapfile -t osp_repos < <(get_osp_repos)
echo "Found ${#osp_repos[@]} repos in ${OSP_ORG}."
echo ""

for name in "${osp_repos[@]}"; do
  [[ -z "$name" ]] && continue

  if is_excluded "$name"; then
    (( skipped++ )) || true
    continue
  fi

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]]; then
    (( skipped++ )) || true
    continue
  fi

  # Check if this repo exists on the upstream — if not, it's OSP-native, skip it
  upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}" 2>/dev/null)
  upstream_exists=$(echo "$upstream_info" | jq -r '.name // empty' 2>/dev/null)

  if [[ -z "$upstream_exists" ]]; then
    (( skipped++ )) || true
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY  would mirror ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name}"
    (( synced++ )) || true
    continue
  fi

  # ── CI gate ────────────────────────────────────────────────────────────────
  # Only mirror when Interested-Deving-1896 is in a clean, stable state:
  #   1. No failing required CI checks on main HEAD
  #   2. No open PRs targeting main (unreviewed content not yet landed)
  # A repo that fails the gate is skipped this run; the next hourly run
  # will retry once the issue is resolved.
  # Repos in NO_GATE_REPOS bypass this check (private CI infrastructure).
  # FORCE=true bypasses the gate for all repos (manual override).
  if [[ "$FORCE" == "true" ]] || is_no_gate "$name"; then
    echo "Mirroring ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name} (gate bypassed)..."
    if mirror_repo "$name"; then
      (( synced++ )) || true
      echo "  done."
    else
      (( failed++ )) || true
    fi
    continue
  fi

  main_sha=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}/branches/main" \
    | jq -r '.commit.sha // empty' 2>/dev/null)

  if [[ -n "$main_sha" ]]; then
    # Check for failing application CI checks on main HEAD.
    # Excluded from the gate:
    #   - Mirror-infrastructure checks (mirror, Mirror to *, setup-osp-mirrors):
    #     gating on a failed mirror job creates a circular dependency.
    #   - CI image build jobs (Build CI image:*): these build Docker images used
    #     by CI itself and require GHCR write permissions not available here.
    #   - Slack notification jobs: notification infrastructure, not app CI.
    failing_checks=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}/commits/${main_sha}/check-runs?per_page=100" \
      | jq -r '[.check_runs[]
          | select(.conclusion == "failure" or .conclusion == "timed_out")
          | select(.name | test("^mirror|^Mirror|setup-osp-mirrors|mirror-osp-to-ooc|^Build CI image:|^slack-notify"; "i") | not)
        ] | length' \
      2>/dev/null || echo 0)

    if [[ "$failing_checks" -gt 0 ]]; then
      echo "  GATE: ${name} has ${failing_checks} failing CI check(s) on main — will retry next run"
      (( gated++ )) || true
      continue
    fi

    # Check for open PRs targeting main
    open_prs=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}/pulls?state=open&base=main&per_page=1" \
      | jq -r 'length' 2>/dev/null || echo 0)

    if [[ "$open_prs" -gt 0 ]]; then
      echo "  GATE: ${name} has ${open_prs} open PR(s) targeting main — will retry next run"
      (( gated++ )) || true
      continue
    fi
  fi
  # ── end CI gate ────────────────────────────────────────────────────────────

  echo "Mirroring ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name}..."

  if mirror_repo "$name"; then
    (( synced++ )) || true
    echo "  done."
  else
    (( failed++ )) || true
  fi
done

echo ""
echo "========================================================"
echo "  Mirror complete: ${UPSTREAM_OWNER} → ${OSP_ORG}"
echo "  Repos synced:  ${synced}"
echo "  Repos skipped: ${skipped}"
echo "  Repos gated:   ${gated}  (failing CI or open PRs on main)"
echo "  Repos failed:  ${failed}"
echo "========================================================"

if [[ "$synced" -eq 0 && "$failed" -gt 0 ]]; then
  echo ""
  echo "All repos failed. Check GH_TOKEN permissions (needs: repo, admin:org, workflow)."
  exit 1
fi

exit 0
