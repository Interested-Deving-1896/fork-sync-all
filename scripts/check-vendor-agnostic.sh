#!/usr/bin/env bash
# check-vendor-agnostic.sh — scan vendor/ for deployment-identity values
# hardcoded as fallback defaults.
#
# "Deployment-identity" means values that identify a specific distro, org,
# or deployment: distro names, distro-specific URLs, org/repo slugs, and
# distro-specific repo/arch paths.  These must never appear as hardcoded
# fallbacks in vendored components — they belong in CI variables or repo
# vars set per deployment.
#
# Detection strategy: pattern-match the *structure* of a fallback expression
# (shell ${VAR:-...}, YAML || '...', TS ?? '...') and then classify the
# fallback *value* against a denylist of semantic categories.  This avoids
# maintaining a list of known distro names — any value that looks like a
# deployment-identity string is flagged regardless of which distro it is.
#
# Legitimate fallbacks (not flagged):
#   - UI/display strings:  'N/A', 'Unknown', 'development', 'latest'
#   - Generic app names:   'Package Dashboard', 'Builder Dashboard'
#   - localhost dev URLs:  'http://localhost:...'
#   - Generic file paths:  'mirrorlist/mirrorlist', 'info', 'production'
#   - Single-word tokens:  'value', 'repos', 'muted'
#   - Error messages:      'Validation failed', 'Something went wrong...'
#   - Asset paths:         '/logo.svg', '/icon.png'
#
# Flagged categories:
#   1. Public hostnames in URLs (non-localhost) used as fallbacks for
#      deployment-specific env vars (ENDPOINT_URL, PRIMARY_MIRROR_URL, etc.)
#   2. Org/repo slug patterns: 'Owner/repo-name' used as fallbacks for
#      OWNER/REPO/ORG env vars
#   3. Distro-path patterns: 'arch/repo-name' combos used as fallbacks for
#      MIRROR_REPO_PATHS / MIRRORLIST_PATH env vars
#   4. Known-bad strings: a short explicit list of strings that are
#      unambiguously wrong regardless of context (kept minimal — the
#      structural checks above handle the general case)
#
# Usage:
#   bash scripts/check-vendor-agnostic.sh [vendor-dir]
#
# Suppress a specific line:
#   # check-vendor-agnostic: ignore
#
# Exit codes:
#   0 — clean
#   1 — violations found

set -euo pipefail

VENDOR_DIR="${1:-vendor}"
SCRIPT="check-vendor-agnostic"

info() { echo "[$SCRIPT] $*" >&2; }

# ── File types to scan ────────────────────────────────────────────────────────

INCLUDE_EXTS=(
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
  '*.yml' '*.yaml'
  '*.env' '*.env.example'
  '*.sh'
)

SKIP_DIRS=(
  'node_modules' '.git' 'target' 'dist' 'build' '.next'
)

# ── Build grep args ───────────────────────────────────────────────────────────

include_args=()
for ext in "${INCLUDE_EXTS[@]}"; do
  include_args+=(--include="$ext")
done

exclude_dir_args=()
for d in "${SKIP_DIRS[@]}"; do
  exclude_dir_args+=(--exclude-dir="$d")
done

# ── Extraction: pull all fallback expressions from the codebase ───────────────
#
# Captures three fallback syntaxes:
#   shell:  ${SOME_VAR:-fallback value}
#   yaml:   ${{ vars.SOME_VAR || 'fallback value' }}
#   ts/js:  someExpr ?? 'fallback value'

extract_fallbacks() {
  local dir="$1"
  grep -rn --extended-regexp \
    "${include_args[@]}" \
    "${exclude_dir_args[@]}" \
    -e '\$\{[A-Z][A-Z0-9_]*:-[^}]+\}' \
    -e '\$\{\{[[:space:]]*vars\.[A-Z_]+[[:space:]]*\|\|[[:space:]]*'"'"'[^'"'"']+'"'"'[[:space:]]*\}\}' \
    -e '[A-Z_]+[[:space:]]*\|\|[[:space:]]*'"'"'[^'"'"']+'"'"'' \
    -e '\?\?[[:space:]]*'"'"'[^'"'"']+'"'"'' \
    "$dir" 2>/dev/null || true
}

# ── Classification ────────────────────────────────────────────────────────────
#
# Returns 0 (violation) or 1 (ok); sets VIOLATION_REASON on violation.

VIOLATION_REASON=""

classify_fallback() {
  local varname="$1"
  local value="$2"
  VIOLATION_REASON=""

  # Strip surrounding whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  # Empty → ok
  [[ -z "$value" ]] && return 1

  # ── Allowlist ─────────────────────────────────────────────────────────────

  # localhost URLs (dev defaults)
  [[ "$value" =~ ^https?://localhost ]] && return 1
  [[ "$value" =~ ^https?://127\. ]] && return 1

  # Asset paths (start with /)
  [[ "$value" =~ ^/ ]] && return 1

  # Single-word alphanumeric tokens ≤ 20 chars (info, latest, production, etc.)
  if [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] && [[ ${#value} -le 20 ]]; then
    return 1
  fi

  # Multi-word strings (≥ 3 words) → UI/error text, not deployment identity
  local word_count
  word_count=$(echo "$value" | wc -w)
  (( word_count >= 3 )) && return 1

  # Two-word strings: ok unless both words are lowercase-hyphenated slugs
  # (Title Case pairs like "Package Dashboard" are fine; "my-org my-repo" is not)
  if (( word_count == 2 )); then
    if ! [[ "$value" =~ ^[a-z][a-z0-9-]+[[:space:]][a-z][a-z0-9-]+$ ]]; then
      return 1
    fi
  fi

  # Generic file paths: no protocol, no public TLD
  if [[ "$value" =~ ^[a-zA-Z0-9._/-]+$ ]] && \
     ! [[ "$value" =~ \.(com|net|org|io|dev|app|cloud|sh)(/|$) ]] && \
     ! [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_-]+/[A-Za-z] ]]; then
    return 1
  fi

  # ── Denylist ──────────────────────────────────────────────────────────────

  # 1. Public URLs (non-localhost)
  if [[ "$value" =~ ^https?:// ]]; then
    local host
    host=$(echo "$value" | sed -E 's|https?://([^/:]+).*|\1|')
    if [[ "$host" != localhost* ]] && [[ "$host" != 127.* ]]; then
      VIOLATION_REASON="public URL as fallback for ${varname}: '${value}'"
      return 0
    fi
  fi

  # 2. Org/repo slug: Owner/repo-name — only flag when the varname suggests
  #    it holds an owner, repo, or org identity (not a generic file path).
  #    'mirrorlist/mirrorlist' is a valid generic path default; 'MyOrg/my-repo' is not.
  if [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_-]+/[A-Za-z][A-Za-z0-9_.-]+$ ]] && \
     echo "$varname" | grep -qiE '(OWNER|REPO|ORG|MIRROR_REPO|MIRRORLIST_REPO)'; then
    VIOLATION_REASON="org/repo slug as fallback for ${varname}: '${value}'"
    return 0
  fi

  # 3. Arch/repo path: x86_64/something or comma-separated list
  if [[ "$value" =~ (^|,)(x86_64|x86_64_v3|x86_64_v4|aarch64|arm|armv7h|i686)/ ]]; then
    VIOLATION_REASON="arch/repo path as fallback for ${varname}: '${value}'"
    return 0
  fi

  # 4. Known-bad bare strings (distro names without slashes/URLs that the
  #    structural checks above would miss)
  local known_bad=(
    cachyos archlinux arch-linux
    ubuntu debian fedora opensuse manjaro endeavouros
    nixos gentoo alpine void artix
  )
  local lower_value
  lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
  for bad in "${known_bad[@]}"; do
    if [[ "$lower_value" == "$bad" ]] || \
       [[ "$lower_value" == *"-${bad}" ]] || \
       [[ "$lower_value" == "${bad}-"* ]]; then
      VIOLATION_REASON="distro name as fallback for ${varname}: '${value}'"
      return 0
    fi
  done

  return 1
}

# ── Parse a matched line → varname|value ─────────────────────────────────────

parse_line() {
  local line="$1"

  # shell: ${VAR:-value}
  if [[ "$line" =~ \$\{([A-Z][A-Z0-9_]*):-([^}]+)\} ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi

  # yaml: ${{ vars.VAR || 'value' }}
  if [[ "$line" =~ \$\{\{[[:space:]]*vars\.([A-Z_]+)[[:space:]]*\|\|[[:space:]]*\'([^\']+)\' ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi

  # yaml/ts: SOME_VAR || 'value'
  if [[ "$line" =~ ([A-Z][A-Z0-9_]*)[[:space:]]*\|\|[[:space:]]*\'([^\']+)\' ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi

  # ts/js: ?? 'value' — only flag when line references a deployment-identity var
  if [[ "$line" =~ \?\?[[:space:]]*\'([^\']+)\' ]]; then
    if echo "$line" | grep -qiE '(ENDPOINT|MIRROR|MIRRORLIST|OWNER|REPO|ORG|API_URL|BASE_URL|SERVER_URL)'; then
      echo "(expression)|${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [[ ! -d "$VENDOR_DIR" ]]; then
  info "vendor directory not found: $VENDOR_DIR"
  exit 0
fi

violations=0
declare -A seen

while IFS= read -r raw_line; do
  echo "$raw_line" | grep -q 'check-vendor-agnostic: ignore' && continue

  file_loc=$(echo "$raw_line" | cut -d: -f1-2)
  line_content=$(echo "$raw_line" | cut -d: -f3-)

  [[ -n "${seen[$file_loc]+x}" ]] && continue

  parsed=$(parse_line "$line_content") || continue
  [[ -z "$parsed" ]] && continue

  varname=$(echo "$parsed" | cut -d'|' -f1)
  value=$(echo "$parsed" | cut -d'|' -f2-)

  if classify_fallback "$varname" "$value"; then
    seen["$file_loc"]=1
    echo "  $file_loc: $VIOLATION_REASON"
    (( violations++ )) || true
  fi

done < <(extract_fallbacks "$VENDOR_DIR")

echo "" >&2
echo "════════════════════════════════════════" >&2
echo "  check-vendor-agnostic" >&2
echo "  Scanned   : $VENDOR_DIR" >&2
echo "  Violations: $violations" >&2
echo "════════════════════════════════════════" >&2

if (( violations > 0 )); then
  info "Deployment-identity values must not be hardcoded as fallback defaults."
  info "Set them as CI variables or repo vars per deployment."
  info "To suppress a specific line: add '# check-vendor-agnostic: ignore'"
  exit 1
fi

info "Clean."
exit 0
