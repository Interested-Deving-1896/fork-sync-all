#!/usr/bin/env bash
#
# ota-payload-build.sh
#
# Assembles the OTA payload for a single opted-in repo by diffing the repo's
# current state against its upstream source, scoped to content OTA owns.
#
# Outputs a directory tree at PAYLOAD_DIR containing only the files that
# differ from what the target repo currently has. The caller (ota-deliver.sh
# or ota-self-update.yml) is responsible for opening a PR with the result.
#
# Usage:
#   PAYLOAD_DIR=/tmp/ota-payload \
#   TARGET_REPO=owner/repo \
#   GH_TOKEN=ghp_... \
#   bash scripts/ota-payload-build.sh [--delta] [--full]
#
#   --delta   Diff from TARGET_PINNED_SHA to upstream HEAD (default for releases)
#   --full    Full sync: reconcile entire repo structure (default for scheduled runs)
#
# Required env:
#   GH_TOKEN          GitHub PAT with repo read access
#   TARGET_REPO       Full repo path (owner/name) of the opted-in fork
#   PAYLOAD_DIR       Directory to write the assembled payload into
#
# Optional env:
#   TARGET_PINNED_SHA  SHA the target is currently pinned to (for --delta mode)
#   UPSTREAM_OVERRIDE  Override upstream source (owner/name); default: fork parent
#   MANIFEST_FILE      Path to template-manifest.yml (default: config/template-manifest.yml)
#   DRY_RUN            "true" to skip writes and only report what would change
#
set -uo pipefail

MODE="${1:---full}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${TARGET_REPO:?TARGET_REPO is required}"
: "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

DRY_RUN="${DRY_RUN:-false}"
MANIFEST_FILE="${MANIFEST_FILE:-config/template-manifest.yml}"
API="https://api.github.com"

# ── helpers ───────────────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"; shift 2
  curl -s -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url"
}

log()  { echo "  [payload] $*"; }
warn() { echo "  [payload] WARN: $*" >&2; }
die()  { echo "  [payload] ERROR: $*" >&2; exit 1; }

# ── resolve upstream ──────────────────────────────────────────────────────────

resolve_upstream() {
  local target="$1"

  # Check for per-repo override in .ota/config.yml
  if [[ -n "${UPSTREAM_OVERRIDE:-}" ]]; then
    echo "$UPSTREAM_OVERRIDE"
    return
  fi

  # Read upstream_override from the target repo's .ota/config.yml if present
  local config_content
  config_content=$(gh_api GET "${API}/repos/${target}/contents/.ota/config.yml" \
    | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
if 'content' in d:
    print(base64.b64decode(d['content']).decode())
" 2>/dev/null || true)

  if [[ -n "$config_content" ]]; then
    local override
    override=$(echo "$config_content" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('upstream_override:'):
        val = line.split(':', 1)[1].strip().strip('\"')
        if val:
            print(val)
" 2>/dev/null || true)
    if [[ -n "$override" ]]; then
      echo "$override"
      return
    fi
  fi

  # Default: GitHub fork parent
  local parent
  parent=$(gh_api GET "${API}/repos/${target}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d.get('parent', {})
print(p.get('full_name', ''))
" 2>/dev/null || true)

  if [[ -z "$parent" ]]; then
    die "Cannot resolve upstream for ${target} — not a fork and no upstream_override set"
  fi
  echo "$parent"
}

# ── build manifest-owned workflow set ────────────────────────────────────────
# Returns the set of workflow filenames that template sync owns (i.e. any
# filename appearing in any profile's include list in template-manifest.yml).
# OTA must not touch these unless the repo's workflow_overrides.claim includes them.

build_manifest_owned_workflows() {
  python3 - "$MANIFEST_FILE" <<'PYEOF'
import sys, re

manifest_file = sys.argv[1]
try:
    with open(manifest_file) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)

# Extract all .github/workflows/*.yml paths from include: blocks
# Simple line-by-line parse — no full YAML dependency needed
owned = set()
for line in content.splitlines():
    line = line.strip().lstrip('- ')
    if line.startswith('.github/workflows/'):
        owned.add(line.split('/')[-1])

for name in sorted(owned):
    print(name)
PYEOF
}

# ── path exclusion check ──────────────────────────────────────────────────────

is_excluded() {
  local path="$1"
  shift
  local patterns=("$@")
  for pattern in "${patterns[@]}"; do
    # Simple glob match using bash
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# ── main ──────────────────────────────────────────────────────────────────────

log "Resolving upstream for ${TARGET_REPO}..."
UPSTREAM=$(resolve_upstream "$TARGET_REPO")
log "Upstream: ${UPSTREAM}"

# Clone upstream at the relevant ref
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

UPSTREAM_URL="https://x-access-token:${GH_TOKEN}@github.com/${UPSTREAM}.git"
TARGET_URL="https://x-access-token:${GH_TOKEN}@github.com/${TARGET_REPO}.git"

log "Cloning upstream ${UPSTREAM}..."
git clone --quiet --depth=1 "$UPSTREAM_URL" "${WORK_DIR}/upstream" 2>/dev/null \
  || die "Failed to clone upstream ${UPSTREAM}"

log "Cloning target ${TARGET_REPO}..."
git clone --quiet --depth=1 "$TARGET_URL" "${WORK_DIR}/target" 2>/dev/null \
  || die "Failed to clone target ${TARGET_REPO}"

# In delta mode, deepen to the pinned SHA
if [[ "$MODE" == "--delta" && -n "${TARGET_PINNED_SHA:-}" ]]; then
  log "Delta mode: deepening upstream to ${TARGET_PINNED_SHA:0:8}..."
  pushd "${WORK_DIR}/upstream" >/dev/null
  git fetch --quiet --depth=100 origin 2>/dev/null || true
  popd >/dev/null
fi

# Build the set of workflow files template sync owns
mapfile -t MANIFEST_WORKFLOWS < <(build_manifest_owned_workflows)
log "Template-sync-owned workflows: ${#MANIFEST_WORKFLOWS[@]} files"

# Read per-repo workflow_overrides from target's .ota/config.yml
CLAIM_WORKFLOWS=()
DISCLAIM_WORKFLOWS=()
if [[ -f "${WORK_DIR}/target/.ota/config.yml" ]]; then
  mapfile -t CLAIM_WORKFLOWS < <(python3 -c "
import sys
in_claim = False
with open('${WORK_DIR}/target/.ota/config.yml') as f:
    for line in f:
        s = line.strip()
        if s == 'claim:':
            in_claim = True
        elif s == 'disclaim:':
            in_claim = False
        elif in_claim and s.startswith('- '):
            print(s[2:].strip())
" 2>/dev/null || true)
  mapfile -t DISCLAIM_WORKFLOWS < <(python3 -c "
import sys
in_disclaim = False
with open('${WORK_DIR}/target/.ota/config.yml') as f:
    for line in f:
        s = line.strip()
        if s == 'disclaim:':
            in_disclaim = True
        elif s == 'claim:':
            in_disclaim = False
        elif in_disclaim and s.startswith('- '):
            print(s[2:].strip())
" 2>/dev/null || true)
fi

# Read per-repo exclude_paths
EXCLUDE_PATHS=()
if [[ -f "${WORK_DIR}/target/.ota/config.yml" ]]; then
  mapfile -t EXCLUDE_PATHS < <(python3 -c "
in_exclude = False
with open('${WORK_DIR}/target/.ota/config.yml') as f:
    for line in f:
        s = line.strip()
        if s == 'exclude_paths:':
            in_exclude = True
        elif s and not s.startswith('- ') and in_exclude:
            in_exclude = False
        elif in_exclude and s.startswith('- '):
            print(s[2:].strip())
" 2>/dev/null || true)
fi

# ── assemble payload ──────────────────────────────────────────────────────────

mkdir -p "$PAYLOAD_DIR"
changed=0
skipped=0

log "Scanning upstream for changed files..."

while IFS= read -r -d '' upstream_file; do
  rel="${upstream_file#${WORK_DIR}/upstream/}"

  # Always skip .git
  [[ "$rel" == .git* ]] && continue
  # Always skip .ota/ — managed separately
  [[ "$rel" == .ota/* ]] && continue

  # Workflow boundary check
  if [[ "$rel" == .github/workflows/* ]]; then
    wf_name="${rel##*/}"

    # Is it in the manifest (template sync owns it)?
    manifest_owned=false
    for mw in "${MANIFEST_WORKFLOWS[@]}"; do
      [[ "$mw" == "$wf_name" ]] && manifest_owned=true && break
    done

    # Apply claim/disclaim overrides
    for cw in "${CLAIM_WORKFLOWS[@]}"; do
      [[ "$cw" == "$wf_name" ]] && manifest_owned=false && break
    done
    for dw in "${DISCLAIM_WORKFLOWS[@]}"; do
      [[ "$dw" == "$wf_name" ]] && manifest_owned=true && break
    done

    if [[ "$manifest_owned" == "true" ]]; then
      (( skipped++ ))
      continue
    fi
  fi

  # Per-repo exclude_paths
  if is_excluded "$rel" "${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}"; then
    (( skipped++ ))
    continue
  fi

  # Compare with target
  target_file="${WORK_DIR}/target/${rel}"
  if [[ -f "$target_file" ]]; then
    if diff -q "$upstream_file" "$target_file" >/dev/null 2>&1; then
      (( skipped++ ))
      continue  # identical — no change needed
    fi
  fi

  # File is new or changed — add to payload
  payload_dest="${PAYLOAD_DIR}/${rel}"
  mkdir -p "$(dirname "$payload_dest")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  would update: ${rel}"
  else
    cp "$upstream_file" "$payload_dest"
  fi
  (( changed++ ))

done < <(find "${WORK_DIR}/upstream" -type f -print0)

log "Payload assembled: ${changed} files changed, ${skipped} files skipped"

if [[ "$changed" -eq 0 ]]; then
  log "No changes — target is already up to date with upstream"
  exit 0
fi

# Write a manifest of changed files for the caller
find "$PAYLOAD_DIR" -type f | sed "s|${PAYLOAD_DIR}/||" | sort \
  > "${PAYLOAD_DIR}/.ota-changed-files"

log "Changed file list written to ${PAYLOAD_DIR}/.ota-changed-files"
exit 0
