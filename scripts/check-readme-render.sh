#!/usr/bin/env bash
#
# check-readme-render.sh — validate README.md for GitHub rendering correctness
#
# Catches issues that cause blank text, hidden content, or broken layout
# in GitHub's Markdown renderer, particularly in AI-generated READMEs:
#
#   1.  Leaked log lines (update-readmes debug output written into file)
#   2.  Unclosed AI marker pairs (<!-- AI:start:X --> without <!-- AI:end:X -->)
#   3.  Unclosed fenced code blocks (unbalanced ``` / ```lang fences)
#   4.  Trailing whitespace in list items (renders as unintended <br>)
#   5.  Empty AI sections (marker pair with no content between them)
#   6.  Missing Ona badge
#   7.  Missing H1 heading
#   8.  Duplicate H1 headings
#   9.  Bare placeholder HTML comments (incomplete sections)
#  10.  Broken table column counts (row/header mismatch)
#  11.  Bare [text] without a URL — GitHub blanks these out
#  12.  Raw angle brackets outside code blocks — parsed as HTML, text hidden
#
# Usage:
#   check-readme-render.sh [README.md]   # check a specific file
#   check-readme-render.sh               # check README.md in CWD
#
# Exit codes:
#   0 — no errors (warnings may still be printed)
#   1 — one or more errors found
#   2 — file not found or unreadable

set -uo pipefail

README="${1:-README.md}"

if [[ ! -f "$README" ]]; then
  echo "check-readme-render: file not found: ${README}" >&2
  exit 2
fi

ERRORS=()
WARNINGS=()

mapfile -t lines < "$README"
total_lines=${#lines[@]}

# ── Fence map ─────────────────────────────────────────────────────────────────
# Build in_fence_map[i]=1 for lines inside a fenced block (0-based).
# Handles plain ```, language-tagged ```bash, and ~~~ fences.
declare -a in_fence_map
fence_open=0
fence_depth=0
fence_char_open=""
for (( i=0; i<total_lines; i++ )); do
  line="${lines[$i]}"
  if [[ "$line" =~ ^([[:space:]]*)(\`\`\`+|~~~+) ]]; then
    marker="${BASH_REMATCH[2]}"
    mchar="${marker:0:1}"
    mlen="${#marker}"
    if (( fence_open == 0 )); then
      fence_open=1
      fence_depth=$mlen
      fence_char_open=$mchar
      in_fence_map[$i]=0   # opening line itself is not "inside"
    elif [[ "$mchar" == "$fence_char_open" ]] && (( mlen >= fence_depth )); then
      fence_open=0
      in_fence_map[$i]=0   # closing line itself is not "inside"
    else
      in_fence_map[$i]=1
    fi
  else
    in_fence_map[$i]=$fence_open
  fi
done

# ── 1. Leaked log lines ───────────────────────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  if [[ "${lines[$i]}" =~ ^\[update-readmes\] ]]; then
    ERRORS+=("line $(( i+1 )): leaked log line — update-readmes output written into file")
  fi
done

# ── 2. Unclosed / orphan AI marker pairs ─────────────────────────────────────
declare -A ai_starts ai_ends
while IFS= read -r section; do
  [[ -n "$section" ]] && ai_starts["$section"]=1
done < <(grep -oP '(?<=<!-- AI:start:)[^ ]+(?= -->)' "$README" 2>/dev/null || true)

while IFS= read -r section; do
  [[ -n "$section" ]] && ai_ends["$section"]=1
done < <(grep -oP '(?<=<!-- AI:end:)[^ ]+(?= -->)' "$README" 2>/dev/null || true)

for section in "${!ai_starts[@]}"; do
  [[ -v ai_ends["$section"] ]] || \
    ERRORS+=("unclosed AI marker: <!-- AI:start:${section} --> has no matching end")
done
for section in "${!ai_ends[@]}"; do
  [[ -v ai_starts["$section"] ]] || \
    ERRORS+=("orphan AI marker: <!-- AI:end:${section} --> has no matching start")
done

# ── 3. Unclosed fenced code blocks ───────────────────────────────────────────
if (( fence_open == 1 )); then
  ERRORS+=("unclosed fenced code block: a \`\`\` or ~~~ block was never closed")
fi

# ── 4. Trailing whitespace in list items ─────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  if [[ "${lines[$i]}" =~ ^[[:space:]]*[-*+][[:space:]].+[[:space:]]{2,}$ ]]; then
    WARNINGS+=("line $(( i+1 )): trailing whitespace in list item (renders as <br>)")
  fi
done

# ── 5. Empty AI sections ─────────────────────────────────────────────────────
for section in "${!ai_starts[@]}"; do
  [[ -v ai_ends["$section"] ]] || continue
  body=$(awk \
    "/<!-- AI:start:${section} -->/{f=1;next} /<!-- AI:end:${section} -->/{f=0} f{print}" \
    "$README" | grep -v '^[[:space:]]*$' || true)
  [[ -z "$body" ]] && \
    WARNINGS+=("empty AI section: <!-- AI:start:${section} --> has no content")
done

# ── 6. Missing Ona badge ──────────────────────────────────────────────────────
grep -qF '[![Built with Ona]' "$README" || \
  WARNINGS+=("missing Ona badge ([![Built with Ona](https://ona.com/build-with-ona.svg)])")

# ── 7 & 8. H1 heading presence and uniqueness ────────────────────────────────
h1_count=0
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  [[ "${lines[$i]}" =~ ^#[[:space:]] ]] && (( h1_count++ )) || true
done
(( h1_count == 0 )) && ERRORS+=("missing H1 heading (no line starting with '# ')")
(( h1_count > 1  )) && ERRORS+=("${h1_count} H1 headings found — only one is allowed")

# ── 9. Bare placeholder HTML comments ────────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  if [[ "${lines[$i]}" =~ ^[[:space:]]*\<\!--[[:space:]]*(Add|Document|TODO|FIXME|TBD) ]]; then
    WARNINGS+=("line $(( i+1 )): bare placeholder comment — section may be incomplete")
  fi
done

# ── 10. Broken table column counts ───────────────────────────────────────────
in_table=0
header_cols=0
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  if [[ "$line" =~ ^\|.*\| ]]; then
    if (( in_table == 0 )); then
      in_table=1
      header_cols=$(echo "$line" | tr -cd '|' | wc -c)
      header_cols=$(( header_cols - 1 ))
    else
      # Skip separator rows (|---|---|)
      [[ "$line" =~ ^\|[-|[:space:]:]+\|$ ]] && continue
      row_cols=$(echo "$line" | tr -cd '|' | wc -c)
      row_cols=$(( row_cols - 1 ))
      if (( row_cols != header_cols )); then
        WARNINGS+=("line $(( i+1 )): table row has ${row_cols} columns, header has ${header_cols}")
      fi
    fi
  else
    in_table=0
    header_cols=0
  fi
done

# ── 11. Bare [text] without a URL ────────────────────────────────────────────
# [text] not followed by ( or [ and not preceded by ! (image syntax).
# GitHub renders these as blank — brackets and text both disappear.
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  # Skip HTML comment lines and AI marker lines
  [[ "$line" =~ ^[[:space:]]*\<\!-- ]] && continue
  # Skip reference-style link definitions: [id]: url
  [[ "$line" =~ ^[[:space:]]*\[[^\]]+\]: ]] && continue
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    WARNINGS+=("line $(( i+1 )): bare [${match}] without URL — GitHub may blank this out")
  done < <(echo "$line" | grep -oP '(?<![!\`])\[([^\]]+)\](?![\(\[`:])' \
    | grep -oP '(?<=\[)[^\]]+' || true)
done

# ── 12. Raw angle brackets outside code blocks ───────────────────────────────
# <word> patterns that aren't known safe HTML tags get parsed as unknown HTML
# elements — GitHub hides them and sometimes the text that follows.
SAFE_TAGS="a|abbr|b|blockquote|br|caption|cite|code|col|colgroup|dd|del"
SAFE_TAGS+="|details|dfn|div|dl|dt|em|figcaption|figure|h1|h2|h3|h4|h5|h6"
SAFE_TAGS+="|hr|i|img|ins|kbd|li|mark|ol|p|pre|q|rp|rt|ruby|s|samp|section"
SAFE_TAGS+="|small|span|strike|strong|sub|summary|sup|table|tbody|td|tfoot"
SAFE_TAGS+="|th|thead|time|tr|tt|u|ul|var|wbr"

for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  [[ "$line" =~ ^[[:space:]]*\<\!-- ]] && continue
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    tag_base="${tag,,}"
    tag_base="${tag_base%%[[:space:]/]*}"
    # Skip safe HTML tags, closing tags, and doctype/comment markers
    [[ "$tag_base" =~ ^(${SAFE_TAGS})$ ]] && continue
    [[ "$tag" =~ ^[/!] ]] && continue
    WARNINGS+=("line $(( i+1 )): raw <${tag}> outside code block — may be hidden by GitHub's HTML sanitiser")
  done < <(echo "$line" | grep -oP '(?<=<)[a-zA-Z][a-zA-Z0-9_.@: -]{1,50}(?=>)' || true)
done

# ── Report ────────────────────────────────────────────────────────────────────
total_errors=${#ERRORS[@]}
total_warnings=${#WARNINGS[@]}

if (( total_errors == 0 && total_warnings == 0 )); then
  echo "check-readme-render: ✅ ${README} — no issues found"
  exit 0
fi

echo "check-readme-render: ${README} — ${total_errors} error(s), ${total_warnings} warning(s)"
echo ""

if (( total_errors > 0 )); then
  echo "  Errors:"
  for e in "${ERRORS[@]}"; do
    echo "    ✗ ${e}"
  done
fi

if (( total_warnings > 0 )); then
  echo "  Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "    ⚠ ${w}"
  done
fi

echo ""
(( total_errors > 0 )) && exit 1 || exit 0
