#!/usr/bin/env bash
#
# check-readme-render.sh — validate README.md for GitHub rendering correctness
#
# Catches issues that cause blank text, hidden content, or broken layout
# in GitHub's Markdown renderer, particularly in AI-generated READMEs:
#
#   1.  Leaked log lines (script log output written into file — any [prefix] pattern)
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
# Cross-platform / mobile rendering checks (GitHub Android app + all browser engines):
#
#  13.  <img align="..."> — CSS align stripped by GFM; images stack vertically on mobile
#  14.  <img> with no alt text — screen readers and some mobile parsers skip these
#  15.  Image URLs with uppercase extensions (.PNG/.JPG/.GIF/.SVG) — Android URL
#       parser is case-sensitive and fails to load the image
#  16.  Image URLs with unencoded spaces — Android app does not auto-encode spaces
#  17.  <div> layout blocks — stripped by GFM sanitiser on all platforms; content lost
#  18.  <kbd> / <sub> / <sup> inside table cells — mobile parser memory pressure /
#       rendering failure; also broken in some WebKit versions
#  19.  Wide tables (> 5 data columns) — no horizontal scroll on mobile; content cut off
#  20.  Very long lines (> 500 chars outside code) — mobile parser memory pressure
#  21.  Deeply nested <details> blocks (> 2 levels) — crashes GitHub Android app parser
#  22.  SVG <img> src not from raw.githubusercontent.com or camo — CSP-blocked on Android
#  23.  Markdown image syntax with non-lowercase extension — same case-sensitivity issue
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
# Matches any line starting with a bracketed kebab-case identifier followed by
# a space — the universal pattern used by info()/warn() across all scripts.
# Examples: [update-readmes] ..., [warn] ..., [sync-template] ..., [INFO] ...
for (( i=0; i<total_lines; i++ )); do
  if [[ "${lines[$i]}" =~ ^\[[a-zA-Z][a-zA-Z0-9_-]*\][[:space:]] ]]; then
    ERRORS+=("line $(( i+1 )): leaked log line — script output written into file: ${lines[$i]:0:60}")
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
    # Skip if the matched text itself contains '[' — nested bracket inside a
    # larger link like [@user[bot]](url).
    [[ "$match" == *"["* ]] && continue
    # Skip GitHub bot suffixes: [bot] appears as a nested bracket inside
    # link text like [@github-actions[bot]](url) and is not a bare bracket.
    [[ "$match" == "bot" ]] && continue
    WARNINGS+=("line $(( i+1 )): bare [${match}] without URL — GitHub may blank this out")
  done < <(echo "$line" | grep -oP '(?<![!`])\[([^\]]+)\](?![\(\[`:])' \
    | sed 's/^\[//;s/\]$//' || true)
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

# ── 13. <img align="..."> — broken on mobile (GFM strips CSS align) ───────────
_img_align_re='<img[^>]* align='
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  if echo "${lines[$i]}" | grep -qP "$_img_align_re"; then
    WARNINGS+=("line $(( i+1 )): <img align=...> — align attribute stripped by GFM; images stack on mobile")
  fi
done

# ── 14. <img> with no alt text ────────────────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  # Match <img ...> tags that lack an alt= attribute entirely
  while IFS= read -r tag_body; do
    [[ -z "$tag_body" ]] && continue
    if ! echo "$tag_body" | grep -qiP 'alt\s*='; then
      WARNINGS+=("line $(( i+1 )): <img> missing alt attribute — skipped by some mobile parsers and screen readers")
    fi
  done < <(echo "$line" | grep -oP '<img\s[^>]+>' || true)
done

# ── 15 & 23. Image URLs with uppercase extensions ─────────────────────────────
# Covers both <img src="..."> and ![alt](url) syntax.
# Android's URL parser is case-sensitive; .PNG/.JPG/.SVG fail to load.
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  # HTML img src
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    ext="${url##*.}"
    if [[ "$ext" =~ ^(PNG|JPG|JPEG|GIF|SVG|WEBP|BMP|ICO)$ ]]; then
      WARNINGS+=("line $(( i+1 )): image URL has uppercase extension .${ext} — Android app fails to load (case-sensitive)")
    fi
  done < <(echo "$line" | grep -oP '(?<=src=")[^"]+' || true)
  # Markdown image syntax ![alt](url)
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    ext="${url##*.}"
    # Strip query strings / fragments before checking extension
    ext="${ext%%[?#]*}"
    if [[ "$ext" =~ ^(PNG|JPG|JPEG|GIF|SVG|WEBP|BMP|ICO)$ ]]; then
      WARNINGS+=("line $(( i+1 )): markdown image URL has uppercase extension .${ext} — Android app fails to load (case-sensitive)")
    fi
  done < <(echo "$line" | grep -oP '!\[[^\]]*\]\([^) ]+' | sed 's/^!\[[^]]*\](\(.*\)/\1/' || true)
done

# ── 16. Image URLs with unencoded spaces ──────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    if [[ "$url" == *" "* ]]; then
      WARNINGS+=("line $(( i+1 )): image URL contains unencoded space — Android app fails to decode path")
    fi
  done < <({ echo "$line" | grep -oP '(?<=src=")[^"]+' ; \
             echo "$line" | grep -oP '!\[[^\]]*\]\([^)]+' | sed 's/^!\[[^]]*\](\(.*\)/\1/' ; } 2>/dev/null || true)
done

# ── 17. <div> layout blocks ───────────────────────────────────────────────────
# GFM sanitiser strips <div> on all platforms; any content inside is lost.
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  if echo "${lines[$i]}" | grep -qP '<div[\s/>]'; then
    WARNINGS+=("line $(( i+1 )): <div> block — stripped by GFM sanitiser on all platforms; use plain Markdown instead")
  fi
done

# ── 18. <kbd>/<sub>/<sup> inside table cells ──────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  [[ "$line" =~ ^\| ]] || continue
  if echo "$line" | grep -qiP '<(kbd|sub|sup)\b'; then
    WARNINGS+=("line $(( i+1 )): <kbd>/<sub>/<sup> inside table cell — causes rendering failure on GitHub Android app and some WebKit versions")
  fi
done

# ── 19. Wide tables (> 5 data columns) ───────────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  [[ "$line" =~ ^\| ]] || continue
  # Skip separator rows
  [[ "$line" =~ ^\|[-|[:space:]:]+\|$ ]] && continue
  col_count=$(echo "$line" | tr -cd '|' | wc -c)
  col_count=$(( col_count - 1 ))
  if (( col_count > 5 )); then
    WARNINGS+=("line $(( i+1 )): table has ${col_count} columns — overflows on mobile (no horizontal scroll); consider splitting or simplifying")
  fi
done

# ── 20. Very long lines outside code blocks ───────────────────────────────────
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  [[ "${#line}" -gt 500 ]] || continue
  # Skip HTML comment lines (AI markers, etc.)
  [[ "$line" =~ ^[[:space:]]*\<\!-- ]] && continue
  WARNINGS+=("line $(( i+1 )): line is ${#line} chars — very long lines cause mobile parser memory pressure (>500 chars)")
done

# ── 21. Deeply nested <details> blocks (> 2 levels) ──────────────────────────
details_depth=0
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  if echo "$line" | grep -qP '<details'; then
    (( details_depth++ )) || true
    if (( details_depth > 2 )); then
      WARNINGS+=("line $(( i+1 )): <details> nested ${details_depth} levels deep — GitHub Android app parser crashes beyond 2 levels")
    fi
  fi
  if echo "$line" | grep -qP '</details>' && (( details_depth > 0 )); then
    (( details_depth-- )) || true
  fi
done

# ── 22. SVG/image src not from trusted GitHub CDN domains ────────────────────
# GitHub Android app enforces strict CSP: only camo.githubusercontent.com and
# raw.githubusercontent.com are allowed for external images. Other hosts are blocked.
TRUSTED_IMG_HOSTS="raw\.githubusercontent\.com|camo\.githubusercontent\.com|github\.com|user-images\.githubusercontent\.com|avatars\.githubusercontent\.com|shields\.io|img\.shields\.io|badge\.fury\.io|badgen\.net|codecov\.io|travis-ci\.(org|com)|circleci\.com|github\.io|ona\.com|app\.ona\.com"
for (( i=0; i<total_lines; i++ )); do
  [[ "${in_fence_map[$i]:-0}" == "1" ]] && continue
  line="${lines[$i]}"
  # Check both <img src="..."> and ![alt](url) for http/https URLs
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    # Only flag absolute http/https URLs
    [[ "$url" =~ ^https?:// ]] || continue
    # Extract hostname
    host=$(echo "$url" | grep -oP '(?<=https?://)[^/]+' || true)
    [[ -z "$host" ]] && continue
    if ! echo "$host" | grep -qP "^(${TRUSTED_IMG_HOSTS})$"; then
      WARNINGS+=("line $(( i+1 )): image from untrusted host '${host}' — may be CSP-blocked on GitHub Android app")
    fi
  done < <({ echo "$line" | grep -oP '(?<=src=")[^"]+' ; \
             echo "$line" | grep -oP '!\[[^\]]*\]\([^) ]+' | sed 's/^!\[[^]]*\](\(.*\)/\1/' ; } 2>/dev/null || true)
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
