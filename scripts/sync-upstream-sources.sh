#!/usr/bin/env bash
#
# Syncs all upstream origin repos referenced in ## Origins sections of
# OSP-bound Interested-Deving-1896 repos.
#
# For each repo in the OSP-bound set:
#   1. Fetch its README from the default branch.
#   2. Parse all GitHub, invent.kde.org, and gitlab.com links from ## Origins.
#   3. For each external origin (not Interested-Deving-1896/*):
#      a. If a fork already exists under GITHUB_OWNER — sync it via
#         merge-upstream (fast-forward) or force-reset to upstream HEAD.
#      b. If no fork exists — report it as missing (forking requires manual
#         action; automated fork creation is excluded to avoid unreviewed repos).
#      c. KDE (invent.kde.org) and non-GitHub GitLab origins are reported as
#         present/missing but not synced here — they are handled by the
#         existing KDE mirror pipelines on the GitLab side.
#
# Required env vars:
#   GH_TOKEN      — PAT with repo scope on Interested-Deving-1896
#   GITHUB_OWNER  — org that holds the forks (default: Interested-Deving-1896)
#
# Optional env vars:
#   DRY_RUN       — set to "true" to report without syncing (default: false)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
DRY_RUN="${DRY_RUN:-false}"

API="https://api.github.com"
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

info() { echo "[sync-upstream-sources] $*"; }
warn() { echo "[warn] $*" >&2; }
dry()  { echo "[dry-run] $*"; }

# ── GitHub API helper ─────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"; shift 2
  local attempt=0 max_retries=3
  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$HEADER_FILE" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      [[ $attempt -gt $max_retries ]] && { echo "$body"; return 1; }
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      [[ "$wait" -gt 0 && "$wait" -lt 3700 ]] && sleep "$wait" || sleep 60
      continue
    fi
    echo "$body"; return 0
  done
}

# ── OSP-bound repo list ───────────────────────────────────────────────────────
# Derived from config/gitlab-subgroups.yml — the single source of truth for
# which repos are mirrored to GitLab. Falls back to a hardcoded list if the
# config file is not found (e.g. when running outside the repo root).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SUBGROUP_CONFIG="${_SCRIPT_DIR}/../config/gitlab-subgroups.yml"

if [[ -f "$_SUBGROUP_CONFIG" ]]; then
  mapfile -t OSP_REPOS < <(python3 - "$_SUBGROUP_CONFIG" <<'PYEOF'
import sys, re
config_path = sys.argv[1]
with open(config_path) as f:
    content = f.read()
in_subgroups = False
for line in content.splitlines():
    if re.match(r'^subgroups:', line):
        in_subgroups = True
        continue
    if not in_subgroups:
        continue
    m = re.match(r'^      - (.+)', line)
    if m:
        print(m.group(1).strip())
PYEOF
  )
else
  OSP_REPOS=(
    btrfs-dwarfs-framework
    eggs-ai
    eggs-gui
    immutable-linux-framework
    liquorix-unified-kernel
    liqxanmod
    lkf
    lkm
    oa-tools
    penguins-eggs
    penguins-eggs-audit
    penguins-eggs-book
    penguins-incus-platform
    penguins-kernel-manager
    penguins-powerwash
    penguins-recovery
    ukm
    xanmod-unified-kernel
  )
fi

# ── README fetch and Origins parsing ─────────────────────────────────────────

get_readme_text() {
  local repo="$1"
  local info content
  for branch in main master develop; do
    info=$(gh_api GET "${API}/repos/${GITHUB_OWNER}/${repo}/contents/README.md?ref=${branch}" 2>/dev/null) || continue
    content=$(echo "$info" | python3 -c \
      "import sys,json,base64
d=json.load(sys.stdin)
raw=d.get('content','')
print(base64.b64decode(raw).decode('utf-8','replace'))" 2>/dev/null) || continue
    [[ -n "$content" ]] && echo "$content" && return 0
  done
  return 1
}

# Extract external origin links from the ## Origins section.
# Emits "host|owner/repo" lines. Skips GITHUB_OWNER-internal links.
parse_origins() {
  local readme="$1"
  local origins_block
  origins_block=$(echo "$readme" | awk '/^## Origins/{f=1;next} f && /^## /{exit} f{print}')
  [[ -z "$origins_block" ]] && return 0

  # GitHub
  echo "$origins_block" \
    | grep -oP 'https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://github.com/||' \
    | grep -iv "^${GITHUB_OWNER}/" \
    | sort -u \
    | sed 's/^/github|/'

  # KDE Invent
  echo "$origins_block" \
    | grep -oP 'https://invent\.kde\.org/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://invent.kde.org/||' \
    | sort -u \
    | sed 's/^/kde|/'

  # GitLab.com (non-openos-project)
  echo "$origins_block" \
    | grep -oP 'https://gitlab\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://gitlab.com/||' \
    | grep -iv "^openos-project/" \
    | sort -u \
    | sed 's/^/gitlab|/'
}

# ── Fork sync helpers ─────────────────────────────────────────────────────────

fork_exists() {
  local name="$1"
  local info
  info=$(gh_api GET "${API}/repos/${GITHUB_OWNER}/${name}" 2>/dev/null) || return 1
  echo "$info" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('name') else 1)" 2>/dev/null
}

fork_default_branch() {
  local name="$1"
  gh_api GET "${API}/repos/${GITHUB_OWNER}/${name}" 2>/dev/null \
    | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('default_branch','main'))" 2>/dev/null \
    || echo "main"
}

upstream_default_branch() {
  local slug="$1"
  gh_api GET "${API}/repos/${slug}" 2>/dev/null \
    | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('default_branch','main'))" 2>/dev/null \
    || echo "main"
}

sync_github_fork() {
  local fork_name="$1" upstream_slug="$2"
  local branch
  branch=$(fork_default_branch "$fork_name")

  local result merge_type
  result=$(gh_api POST "${API}/repos/${GITHUB_OWNER}/${fork_name}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"${branch}\"}") || true
  merge_type=$(echo "$result" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('merge_type',''))" 2>/dev/null || true)

  case "$merge_type" in
    fast-forward) info "    fast-forwarded"; return 0 ;;
    none)         info "    already up to date"; return 0 ;;
    merge)        info "    merged"; return 0 ;;
  esac

  # Fallback: force-reset to upstream HEAD
  local upstream_branch upstream_ref upstream_sha
  upstream_branch=$(upstream_default_branch "$upstream_slug")
  upstream_ref=$(gh_api GET "${API}/repos/${upstream_slug}/git/ref/heads/${upstream_branch}") || {
    warn "    force-reset failed: could not fetch upstream ref"
    return 1
  }
  upstream_sha=$(echo "$upstream_ref" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('object',{}).get('sha',''))" 2>/dev/null || true)
  [[ -z "$upstream_sha" ]] && { warn "    force-reset failed: no SHA"; return 1; }

  local patch_result new_sha
  patch_result=$(gh_api PATCH \
    "${API}/repos/${GITHUB_OWNER}/${fork_name}/git/refs/heads/${branch}" \
    -H "Content-Type: application/json" \
    -d "{\"sha\":\"${upstream_sha}\",\"force\":true}") || {
    warn "    force-reset failed"; return 1
  }
  new_sha=$(echo "$patch_result" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('object',{}).get('sha',''))" 2>/dev/null || true)
  [[ -n "$new_sha" ]] && info "    force-reset to ${new_sha:0:7}" && return 0
  warn "    force-reset: unexpected response"
  return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

[[ "$DRY_RUN" == "true" ]] && info "DRY RUN — no syncs will be performed"
info "Scanning ${#OSP_REPOS[@]} OSP-bound repos for Origins..."
echo ""

declare -A seen_origins  # "host|slug" → 1 — deduplicates across repos

synced=0
skipped=0
missing=0
failed=0

for repo in "${OSP_REPOS[@]}"; do
  info "── ${repo}"

  readme=$(get_readme_text "$repo") || {
    warn "  No README found — skipping"
    continue
  }

  if ! echo "$readme" | grep -q "^## Origins"; then
    info "  No Origins section — skipping (run patch-origins-sections.sh first)"
    continue
  fi

  origin_count=0
  while IFS='|' read -r host slug; do
    [[ -z "$host" || -z "$slug" ]] && continue
    local_key="${host}|${slug}"
    [[ -v seen_origins["$local_key"] ]] && continue
    seen_origins["$local_key"]=1
    (( origin_count++ )) || true

    fork_name="${slug##*/}"
    info "  ${host}: ${slug}"

    case "$host" in
      github)
        if fork_exists "$fork_name"; then
          if [[ "$DRY_RUN" == "true" ]]; then
            dry "    Would sync ${GITHUB_OWNER}/${fork_name} ← github.com/${slug}"
            (( synced++ )) || true
          else
            if sync_github_fork "$fork_name" "$slug"; then
              (( synced++ )) || true
            else
              (( failed++ )) || true
            fi
          fi
        else
          warn "    MISSING: no fork at ${GITHUB_OWNER}/${fork_name} (upstream: github.com/${slug})"
          (( missing++ )) || true
        fi
        ;;
      kde)
        # KDE repos are mirrored via sync-kde-groups-mirrors.sh on the GitLab side.
        # On the GitHub side we only verify the fork exists; no sync needed here.
        if fork_exists "$fork_name"; then
          info "    present at ${GITHUB_OWNER}/${fork_name} (KDE — synced via GitLab KDE mirror pipeline)"
          (( skipped++ )) || true
        else
          warn "    MISSING: no fork at ${GITHUB_OWNER}/${fork_name} (upstream: invent.kde.org/${slug})"
          (( missing++ )) || true
        fi
        ;;
      gitlab)
        if fork_exists "$fork_name"; then
          info "    present at ${GITHUB_OWNER}/${fork_name} (GitLab — synced via GitLab mirror pipeline)"
          (( skipped++ )) || true
        else
          warn "    MISSING: no fork at ${GITHUB_OWNER}/${fork_name} (upstream: gitlab.com/${slug})"
          (( missing++ )) || true
        fi
        ;;
    esac
  done < <(parse_origins "$readme")

  # A repo whose Origins section only references internal I-D-1896 repos
  # (e.g. lkm = lkf + ukm) will have origin_count=0 here because internal
  # links are filtered out by parse_origins. That is correct — there are no
  # external forks to sync for such repos.
  if echo "$readme" | grep -q "^## Origins" && [[ "${origin_count:-0}" -eq 0 ]]; then
    info "  Origins section present but all references are internal — nothing to sync"
  fi
done

echo ""
echo "════════════════════════════════════════════════════"
echo "  sync-upstream-sources complete"
echo "  GitHub synced : ${synced}"
echo "  KDE/GL noted  : ${skipped}  (handled by mirror pipelines)"
echo "  Missing forks : ${missing}  (manual fork needed)"
echo "  Failed        : ${failed}"
echo "════════════════════════════════════════════════════"

[[ "$failed" -gt 0 ]] && exit 1
exit 0
