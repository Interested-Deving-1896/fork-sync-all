#!/usr/bin/env bash
#
# translate-docs.sh
#
# Translates mdBook documentation pages and other markdown files in DOCS/
# into one or more target languages. Writes translated files to
# DOCS/<lang>/<filename>.md and updates DOCS/SUMMARY.md to include the
# translated pages as a collapsible language section.
#
# Translation direction:
#   SOURCE_LANG (default: en) → TARGET_LANG (default: it)
#   SOURCE_LANG=auto detects the language of each file before translating.
#
# Staleness detection:
#   Each translated file carries a <!-- translated-from-sha: <git-sha> -->
#   watermark. Files are only retranslated when the source has changed.
#   Pass FORCE=true to retranslate regardless.
#
# SUMMARY.md management:
#   After translating, the script upserts a language section in SUMMARY.md
#   between <!-- i18n:<lang>:start --> and <!-- i18n:<lang>:end --> markers.
#   If the markers don't exist they are appended. The section mirrors the
#   structure of the English SUMMARY.md with translated page titles.
#
# Required env vars:
#   GH_TOKEN      — PAT with models:read scope (for GitHub Models API)
#
# Optional env vars:
#   SOURCE_LANG       — BCP-47 source language code (default: en)
#   TARGET_LANG       — BCP-47 target language code (default: it)
#   DOCS_DIR          — path to docs source directory (default: DOCS)
#   FILES             — space-separated list of filenames to translate;
#                       empty = all .md files in DOCS_DIR (excluding SUMMARY.md,
#                       generated/, and already-translated <lang>/ subdirs)
#   FORCE             — "true" to retranslate even if source SHA unchanged
#   DRY_RUN           — "true" to print without writing files
#   MODEL             — GitHub Models model ID (default: openai/gpt-4o)
#   COMMIT            — "true" to git-commit translated files (default: true)
#   BUDGET_MINUTES    — time budget in minutes (default: 55)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

SOURCE_LANG="${SOURCE_LANG:-en}"
TARGET_LANG="${TARGET_LANG:-it}"
DOCS_DIR="${DOCS_DIR:-DOCS}"
FILES="${FILES:-}"
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
MODEL="${MODEL:-openai/gpt-4o}"
COMMIT="${COMMIT:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/llm.sh"

budget_init

info() { echo "[translate-docs] $*" >&2; }
warn() { echo "[translate-docs] ⚠️  $*" >&2; }
dry()  { echo "[translate-docs] [dry-run] $*" >&2; }
ok()   { echo "[translate-docs] ✓ $*" >&2; }

[[ "$DRY_RUN" == "true" ]] && info "DRY RUN — no files will be written"

DOCS_ABS="${REPO_ROOT}/${DOCS_DIR}"
if [[ ! -d "$DOCS_ABS" ]]; then
  warn "DOCS_DIR '${DOCS_DIR}' not found — exiting."
  exit 0
fi

tgt_name=$(lang_name "$TARGET_LANG")
src_name=$(lang_name "$SOURCE_LANG")
TGT_DIR="${DOCS_ABS}/${TARGET_LANG}"

info "Translating ${DOCS_DIR}/ from ${src_name} → ${tgt_name}"
info "Output directory: ${DOCS_DIR}/${TARGET_LANG}/"

# ── File discovery ────────────────────────────────────────────────────────────
# Collect source files to translate. Excludes:
#   - SUMMARY.md (managed separately below)
#   - generated/ subdirectory (auto-generated, not human-authored)
#   - Any existing <lang>/ subdirectories (already translated)
#   - Files starting with a BCP-47 code pattern (e.g. fr/, de/)

if [[ -n "$FILES" ]]; then
  mapfile -t SOURCE_FILES < <(echo "$FILES" | tr ' ' '\n' | grep -v '^$')
else
  mapfile -t SOURCE_FILES < <(
    find "$DOCS_ABS" -maxdepth 1 -name "*.md" ! -name "SUMMARY.md" \
      -printf "%f\n" | sort
    find "$DOCS_ABS" -mindepth 2 -maxdepth 2 -name "*.md" \
      ! -path "*/generated/*" \
      ! -path "*/${TARGET_LANG}/*" \
      | grep -vE "/${TARGET_LANG}/" \
      | sed "s|${DOCS_ABS}/||" | sort
  )
fi

info "Files to translate: ${#SOURCE_FILES[@]}"

# ── SHA helper ────────────────────────────────────────────────────────────────
# Returns the git blob SHA of a file, or a content hash if not tracked.
file_sha() {
  local path="$1"
  git -C "$REPO_ROOT" hash-object "$path" 2>/dev/null \
    || sha256sum "$path" 2>/dev/null | cut -d' ' -f1 \
    || echo "unknown"
}

# ── Watermark helpers ─────────────────────────────────────────────────────────
# Reads the stored source SHA from a translated file's watermark comment.
read_watermark_sha() {
  local path="$1"
  grep -oP '(?<=<!-- translated-from-sha: )[a-f0-9]+(?= -->)' "$path" 2>/dev/null | head -1 || echo ""
}

# Prepends watermark + auto-edit warning to translated content.
wrap_with_watermark() {
  local src_sha="$1" src_file="$2" tgt_lang_name="$3"
  local content="$4"
  printf '<!-- translated-from-sha: %s -->\n' "$src_sha"
  printf '<!-- Automatically translated from %s to %s by translate-docs.sh -->\n' "$src_file" "$tgt_lang_name"
  printf '<!-- Do not edit manually — changes will be overwritten on the next translation run -->\n'
  printf '\n'
  printf '%s\n' "$content"
}

# ── Translation loop ──────────────────────────────────────────────────────────
mkdir -p "$TGT_DIR"

translated=0
skipped=0
failed=0

for rel_path in "${SOURCE_FILES[@]}"; do
  budget_check "$rel_path" || break

  src_abs="${DOCS_ABS}/${rel_path}"
  [[ ! -f "$src_abs" ]] && { warn "  Not found: ${rel_path} — skipping"; continue; }

  # Detect source language if auto
  src_text=$(cat "$src_abs")
  actual_src_lang="$SOURCE_LANG"
  if [[ "$SOURCE_LANG" == "auto" ]]; then
    actual_src_lang=$(detect_language "$src_text")
    info "  ${rel_path}: detected source language = $(lang_name "$actual_src_lang")"
  fi

  # Skip if source and target are the same language
  if [[ "$actual_src_lang" == "$TARGET_LANG" ]]; then
    info "  ${rel_path}: source == target (${TARGET_LANG}) — skipping"
    (( skipped++ )) || true
    continue
  fi

  # Destination path mirrors the source structure under TGT_DIR
  # e.g. DOCS/architecture.md → DOCS/it/architecture.md
  #      DOCS/ops/runbooks.md → DOCS/it/ops/runbooks.md
  tgt_rel="${TARGET_LANG}/${rel_path}"
  tgt_abs="${DOCS_ABS}/${tgt_rel}"
  mkdir -p "$(dirname "$tgt_abs")"

  # Staleness check
  src_sha=$(file_sha "$src_abs")
  if [[ -f "$tgt_abs" && "$FORCE" != "true" ]]; then
    stored_sha=$(read_watermark_sha "$tgt_abs")
    if [[ -n "$stored_sha" && "$stored_sha" == "$src_sha" ]]; then
      info "  ${rel_path}: up to date (SHA unchanged) — skipping"
      (( skipped++ )) || true
      continue
    fi
  fi

  info "  Translating ${rel_path} → ${tgt_rel} ..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "  Would write ${tgt_rel}"
    (( translated++ )) || true
    continue
  fi

  translated_text=$(llm_translate "$src_text" "$(lang_name "$actual_src_lang")" "$tgt_name") || {
    warn "  Translation failed for ${rel_path} — skipping"
    (( failed++ )) || true
    continue
  }

  final_content=$(wrap_with_watermark "$src_sha" "$rel_path" "$tgt_name" "$translated_text")
  printf '%s\n' "$final_content" > "$tgt_abs"
  ok "  Written: ${tgt_rel}"
  (( translated++ )) || true
done

# ── SUMMARY.md update ─────────────────────────────────────────────────────────
# Upserts a language section in DOCS/SUMMARY.md between marker comments.
# The section title is the language name in the target language (e.g. "Italiano").
# Each entry mirrors the English SUMMARY.md structure, with translated titles
# fetched from the first H1 of each translated file.

SUMMARY="${DOCS_ABS}/SUMMARY.md"

update_summary() {
  [[ ! -f "$SUMMARY" ]] && return 0
  [[ "$DRY_RUN" == "true" ]] && { dry "Would update SUMMARY.md with ${TARGET_LANG} section"; return 0; }

  local start_marker="<!-- i18n:${TARGET_LANG}:start -->"
  local end_marker="<!-- i18n:${TARGET_LANG}:end -->"

  # Build the new section content
  local section_lines=()
  section_lines+=("${start_marker}")
  section_lines+=("")
  section_lines+=("# ${tgt_name}")
  section_lines+=("")

  # Walk translated files in the same order as they appear in SUMMARY.md
  local md_link_re='^\s*-?\s*\[([^]]+)\]\(([^)]+\.md)\)'
  while IFS= read -r line; do
    # Match SUMMARY.md entries: - [Title](path.md) or [Title](path.md)
    if [[ "$line" =~ $md_link_re ]]; then
      local title="${BASH_REMATCH[1]}"
      local src_rel="${BASH_REMATCH[2]}"
      local tgt_rel="${TARGET_LANG}/${src_rel}"
      local tgt_abs_check="${DOCS_ABS}/${tgt_rel}"

      [[ ! -f "$tgt_abs_check" ]] && continue

      # Get translated title from first H1 of translated file
      local tgt_title
      tgt_title=$(grep -m1 "^# " "$tgt_abs_check" 2>/dev/null | sed 's/^# //' || echo "$title")

      # Preserve leading whitespace/list marker from original line
      local prefix
      prefix=$(echo "$line" | grep -oP '^[\s-]*(?=\[)' || echo "- ")
      section_lines+=("${prefix}[${tgt_title}](${tgt_rel})")
    fi
  done < "$SUMMARY"

  section_lines+=("")
  section_lines+=("${end_marker}")

  local new_section
  new_section=$(printf '%s\n' "${section_lines[@]}")

  if grep -qF "$start_marker" "$SUMMARY"; then
    # Replace existing section between markers
    python3 - "$SUMMARY" "$start_marker" "$end_marker" "$new_section" <<'PYEOF'
import sys
path, start, end, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path).readlines()
out = []
inside = False
for line in lines:
    if line.rstrip() == start:
        inside = True
        out.append(new + '\n')
        continue
    if line.rstrip() == end:
        inside = False
        continue
    if not inside:
        out.append(line)
open(path, 'w').writelines(out)
PYEOF
    ok "Updated ${TARGET_LANG} section in SUMMARY.md"
  else
    # Append new section at end of file
    {
      echo ""
      printf '%s\n' "${section_lines[@]}"
    } >> "$SUMMARY"
    ok "Appended ${TARGET_LANG} section to SUMMARY.md"
  fi
}

if [[ "$translated" -gt 0 || "$FORCE" == "true" ]]; then
  update_summary
fi

# ── Git commit ────────────────────────────────────────────────────────────────
if [[ "$COMMIT" == "true" && "$DRY_RUN" != "true" && "$translated" -gt 0 ]]; then
  cd "$REPO_ROOT"
  git add "${DOCS_DIR}/${TARGET_LANG}/" "${DOCS_DIR}/SUMMARY.md" 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -m "docs: translate ${DOCS_DIR}/ to ${tgt_name} [auto]" \
      -m "Translated ${translated} file(s) from ${src_name} to ${tgt_name}." \
      --author "github-actions[bot] <github-actions[bot]@users.noreply.github.com>"
    ok "Committed ${translated} translated file(s)"
  else
    info "Nothing to commit."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" >&2
echo "════════════════════════════════════════════" >&2
echo "  translate-docs complete" >&2
echo "  Translated : ${translated}" >&2
echo "  Skipped    : ${skipped}  (up to date or same language)" >&2
echo "  Failed     : ${failed}" >&2
echo "════════════════════════════════════════════" >&2

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Docs Translation — ${src_name} → ${tgt_name}"
    echo ""
    echo "| Result | Count |"
    echo "|--------|-------|"
    echo "| Translated | ${translated} |"
    echo "| Skipped (up to date) | ${skipped} |"
    echo "| Failed | ${failed} |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

[[ "$failed" -gt 0 ]] && exit 1
budget_report
exit 0
