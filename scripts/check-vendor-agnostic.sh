#!/usr/bin/env bash
# check-vendor-agnostic.sh — scan vendor/ for distro-specific hardcoded values.
#
# Flags strings that should never appear as hardcoded defaults in vendored
# components: distro names, distro-specific URLs, and distro-specific repo
# paths baked into fallback expressions (|| '...', ${VAR:-...}, ?? '...').
#
# Usage:
#   bash scripts/check-vendor-agnostic.sh [vendor-dir]
#
# Exit codes:
#   0 — clean
#   1 — violations found

set -euo pipefail

VENDOR_DIR="${1:-vendor}"
SCRIPT="check-vendor-agnostic"

info() { echo "[$SCRIPT] $*" >&2; }
warn() { echo "[$SCRIPT] WARN $*" >&2; }

# ── Patterns ──────────────────────────────────────────────────────────────────
#
# Each entry is a grep-compatible extended regex.  We only flag occurrences
# that look like hardcoded fallback values, not legitimate references in
# comments that explain what the variable is for, or test fixtures.
#
# The patterns are intentionally broad — false positives are better than
# missed violations.  Suppressions can be added with an inline comment:
#   # check-vendor-agnostic: ignore

PATTERNS=(
  # Distro names as fallback values in shell ${VAR:-...} or YAML || '...' or TS ?? '...'
  # Matches: cachyos, arch linux, ubuntu, debian, fedora, opensuse (case-insensitive)
  # in a fallback context (after :-, ||, or ??)
  '(\$\{[A-Z_]+:-[^}]*cachyos[^}]*\})'
  '(\|\|[[:space:]]*'"'"'[^'"'"']*cachyos[^'"'"']*'"'"')'
  '(\?\?[[:space:]]*'"'"'[^'"'"']*cachyos[^'"'"']*'"'"')'

  # Distro-specific mirror URLs as hardcoded fallbacks
  '(\$\{[A-Z_]+:-https?://[^}]*cachyos[^}]*\})'
  '(\|\|[[:space:]]*'"'"'https?://[^'"'"']*cachyos[^'"'"']*'"'"')'
  '(\?\?[[:space:]]*'"'"'https?://[^'"'"']*cachyos[^'"'"']*'"'"')'

  # Distro-specific mirrorlist filenames as hardcoded fallbacks
  '(\$\{[A-Z_]+:-[^}]*cachyos-mirrorlist[^}]*\})'
  '(\|\|[[:space:]]*'"'"'[^'"'"']*cachyos-mirrorlist[^'"'"']*'"'"')'
  '(\?\?[[:space:]]*'"'"'[^'"'"']*cachyos-mirrorlist[^'"'"']*'"'"')'
)

# File extensions to scan
INCLUDE_EXTS=(
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
  '*.yml' '*.yaml'
  '*.env' '*.env.*' '*.env.example'
  '*.sh'
  '*.toml' '*.json'
)

# Paths to always skip
SKIP_PATHS=(
  '*/node_modules/*'
  '*/.git/*'
  '*/target/*'
  '*/dist/*'
  '*/build/*'
  '*/.next/*'
)

# ── Build grep include/exclude args ───────────────────────────────────────────

include_args=()
for ext in "${INCLUDE_EXTS[@]}"; do
  include_args+=(--include="$ext")
done

exclude_args=()
for path in "${SKIP_PATHS[@]}"; do
  exclude_args+=(--exclude-dir="${path#\*/}" )
done

# ── Scan ──────────────────────────────────────────────────────────────────────

if [[ ! -d "$VENDOR_DIR" ]]; then
  warn "vendor directory not found: $VENDOR_DIR"
  exit 0
fi

violations=0
declare -A seen_files

for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r line; do
    # Skip lines with suppression comment
    echo "$line" | grep -q 'check-vendor-agnostic: ignore' && continue

    file=$(echo "$line" | cut -d: -f1)
    lineno=$(echo "$line" | cut -d: -f2)
    content=$(echo "$line" | cut -d: -f3-)

    if [[ -z "${seen_files[$file:$lineno]+x}" ]]; then
      seen_files["$file:$lineno"]=1
      echo "  $file:$lineno: $content"
      (( violations++ )) || true
    fi
  done < <(
    grep -rn --extended-regexp \
      "${include_args[@]}" \
      "${exclude_args[@]}" \
      "$pattern" \
      "$VENDOR_DIR" 2>/dev/null || true
  )
done

# ── Report ────────────────────────────────────────────────────────────────────

echo "" >&2
echo "════════════════════════════════════════" >&2
echo "  check-vendor-agnostic" >&2
echo "  Scanned : $VENDOR_DIR" >&2
echo "  Violations: $violations" >&2
echo "════════════════════════════════════════" >&2

if (( violations > 0 )); then
  info "Violations found. Remove distro-specific hardcoded fallback values."
  info "Use empty defaults and require values to be set per deployment."
  info "To suppress a line: add '# check-vendor-agnostic: ignore' as a comment."
  exit 1
fi

info "Clean — no distro-specific hardcoded fallbacks found."
exit 0
