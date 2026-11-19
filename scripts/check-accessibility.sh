#!/usr/bin/env bash
#
# check-accessibility.sh
#
# Runs a multi-layer accessibility audit for a single repo:
#
#   1. CODEOWNERS audit   — ownership coverage %, unowned files, validation
#                           (requires github-codeowners npm package)
#   2. README scan        — missing alt text, empty link text, tables without
#                           headers, reading level estimate, bare URLs
#   3. WCAG HTML scan     — pa11y against DOCS/generated/ HTML if present
#                           (requires pa11y + Node.js on runner)
#   4. Audio overview     — espeak-ng TTS of README plain text → README.audio.mp3
#                           (requires espeak-ng + ffmpeg on runner)
#   5. Braille output     — liblouis translation of README → README.brl
#                           (requires python3-louis on runner)
#
# Outputs:
#   accessibility-report.json   — machine-readable summary of all checks
#   README.audio.mp3            — audio overview (if espeak-ng available)
#   README.brl                  — Braille Grade 2 output (if liblouis available)
#
# Required env:
#   REPO_DIR        — path to checked-out repo (default: current directory)
#
# Optional env:
#   OWNER           — repo owner (for summary links)
#   REPO            — repo name (for summary links)
#   AUDIO_ENABLED   — "true" to generate audio overview (default: auto-detect)
#   BRAILLE_ENABLED — "true" to generate Braille output (default: auto-detect)
#   WCAG_ENABLED    — "true" to run pa11y HTML scan (default: auto-detect)
#   FAIL_ON_ERROR   — "true" to exit 1 on any ERROR-level finding (default: false)
#   OUTPUT_DIR      — directory for output artifacts (default: REPO_DIR)

set -uo pipefail

REPO_DIR="${REPO_DIR:-$(pwd)}"
OWNER="${OWNER:-unknown}"
REPO="${REPO:-unknown}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-false}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}}"

# Auto-detect optional capabilities
AUDIO_ENABLED="${AUDIO_ENABLED:-$(command -v espeak-ng &>/dev/null && echo true || echo false)}"
BRAILLE_ENABLED="${BRAILLE_ENABLED:-$(python3 -c 'import louis' 2>/dev/null && echo true || echo false)}"
WCAG_ENABLED="${WCAG_ENABLED:-$(command -v pa11y &>/dev/null && echo true || echo false)}"

# ── Logging ───────────────────────────────────────────────────────────────────

info()  { echo "[accessibility] $*" >&2; }
warn()  { echo "[accessibility] WARN: $*" >&2; }
ok()    { echo "[accessibility] ✅ $*" >&2; }
fail()  { echo "[accessibility] ❌ $*" >&2; }
skip()  { echo "[accessibility] ⏭  $*" >&2; }

# ── Report builder ────────────────────────────────────────────────────────────

FINDINGS=()   # array of JSON objects
errors=0
warnings=0
passes=0

add_finding() {
  local level="$1" category="$2" message="$3" detail="${4:-}"
  FINDINGS+=("{\"level\":\"${level}\",\"category\":\"${category}\",\"message\":$(echo "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))'),\"detail\":$(echo "$detail" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}")
  case "$level" in
    ERROR)   (( errors++ ))   || true; fail "${category}: ${message}" ;;
    WARNING) (( warnings++ )) || true; warn "${category}: ${message}" ;;
    PASS)    (( passes++ ))   || true; ok   "${category}: ${message}" ;;
  esac
}

# ── 1. CODEOWNERS audit ───────────────────────────────────────────────────────

run_codeowners_audit() {
  info "── CODEOWNERS audit"

  local codeowners_path=""
  for p in "${REPO_DIR}/.github/CODEOWNERS" "${REPO_DIR}/CODEOWNERS" "${REPO_DIR}/docs/CODEOWNERS"; do
    [[ -f "$p" ]] && codeowners_path="$p" && break
  done

  if [[ -z "$codeowners_path" ]]; then
    add_finding "WARNING" "codeowners" "No CODEOWNERS file found" \
      "Create .github/CODEOWNERS to assign ownership to all files. See https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners"
    return
  fi

  add_finding "PASS" "codeowners" "CODEOWNERS file found at ${codeowners_path#${REPO_DIR}/}"

  # Validate CODEOWNERS with github-codeowners if available
  if command -v github-codeowners &>/dev/null; then
    info "  Running github-codeowners validate..."
    local validate_out
    validate_out=$(cd "$REPO_DIR" && github-codeowners validate 2>&1) || true
    if echo "$validate_out" | grep -qi "error\|invalid\|duplicate\|no match"; then
      add_finding "WARNING" "codeowners" "CODEOWNERS validation issues found" "$validate_out"
    else
      add_finding "PASS" "codeowners" "CODEOWNERS file is valid"
    fi

    info "  Running github-codeowners audit (ownership stats)..."
    local audit_out total_files owned_files unowned_files coverage
    audit_out=$(cd "$REPO_DIR" && github-codeowners audit -s 2>&1) || true
    total_files=$(echo "$audit_out"  | grep -oP 'Total:\s+\K[0-9]+' || echo 0)
    owned_files=$(echo "$audit_out"  | grep -oP 'Loved:\s+\K[0-9]+'  || echo 0)
    unowned_files=$(echo "$audit_out" | grep -oP 'Unloved:\s+\K[0-9]+' || echo 0)

    if [[ "$total_files" -gt 0 ]]; then
      coverage=$(python3 -c "print(round(${owned_files}/${total_files}*100,1))" 2>/dev/null || echo 0)
      if python3 -c "exit(0 if float('${coverage}') >= 80 else 1)" 2>/dev/null; then
        add_finding "PASS" "codeowners" "Ownership coverage: ${coverage}% (${owned_files}/${total_files} files)"
      elif python3 -c "exit(0 if float('${coverage}') >= 50 else 1)" 2>/dev/null; then
        add_finding "WARNING" "codeowners" "Ownership coverage: ${coverage}% (${unowned_files} unowned files)" \
          "Run: github-codeowners audit -u  to list unowned files"
      else
        add_finding "ERROR" "codeowners" "Low ownership coverage: ${coverage}% (${unowned_files}/${total_files} files unowned)" \
          "Run: github-codeowners audit -u  to list unowned files and assign owners in CODEOWNERS"
      fi
    fi
  else
    skip "github-codeowners not installed — skipping ownership stats (npm install -g github-codeowners)"
  fi
}

# ── 2. README accessibility scan ─────────────────────────────────────────────

run_readme_scan() {
  info "── README scan"

  local readme_path="${REPO_DIR}/README.md"
  if [[ ! -f "$readme_path" ]]; then
    add_finding "WARNING" "readme" "No README.md found"
    return
  fi

  local content
  content=$(cat "$readme_path")
  local line_count
  line_count=$(wc -l < "$readme_path")

  # Missing alt text on images: ![](url) or ![ ](url) — empty alt text
  local missing_alt
  missing_alt=$(grep -nP '!\[\s*\]\(' "$readme_path" || true)
  if [[ -n "$missing_alt" ]]; then
    local count
    count=$(echo "$missing_alt" | wc -l)
    add_finding "ERROR" "readme" "${count} image(s) missing alt text" \
      "$(echo "$missing_alt" | head -5)"
  else
    add_finding "PASS" "readme" "All images have alt text"
  fi

  # Empty / non-descriptive link text
  local bad_links
  bad_links=$(grep -inP '\[(click here|here|link|read more|more|this|see here)\]\(' "$readme_path" || true)
  if [[ -n "$bad_links" ]]; then
    local count
    count=$(echo "$bad_links" | wc -l)
    add_finding "WARNING" "readme" "${count} non-descriptive link text(s) found (e.g. 'click here', 'here')" \
      "$(echo "$bad_links" | head -5)"
  else
    add_finding "PASS" "readme" "No non-descriptive link text found"
  fi

  # Tables without header separator rows (| --- | pattern)
  local table_headers table_separators
  table_headers=$(grep -c "^|" "$readme_path" 2>/dev/null || echo 0)
  table_separators=$(grep -cP "^\|[\s\-\|:]+\|" "$readme_path" 2>/dev/null || echo 0)
  if [[ "$table_headers" -gt 0 && "$table_separators" -eq 0 ]]; then
    add_finding "ERROR" "readme" "Table(s) found without header separator rows" \
      "Screen readers use the separator row to identify column headers. Add |---|---| rows."
  elif [[ "$table_headers" -gt 0 ]]; then
    add_finding "PASS" "readme" "Tables have header separator rows"
  fi

  # Bare URLs (not inside markdown link syntax)
  local bare_urls
  bare_urls=$(grep -nP '(?<!\()(https?://[^\s\)>]+)(?!\))' "$readme_path" \
    | grep -vP '^\s*<!--' \
    | grep -vP '\]\(https?://' \
    | grep -vP '^\s*-\s+https?://' \
    | head -5 || true)
  if [[ -n "$bare_urls" ]]; then
    add_finding "WARNING" "readme" "Bare URLs found — wrap in descriptive link text for screen readers" \
      "$(echo "$bare_urls" | head -3)"
  else
    add_finding "PASS" "readme" "No bare URLs found"
  fi

  # Reading level estimate — avg sentence length (simple heuristic)
  local word_count sentence_count avg_sentence_len
  word_count=$(echo "$content" | wc -w)
  sentence_count=$(echo "$content" | grep -oP '[.!?]' | wc -l)
  if [[ "$sentence_count" -gt 0 ]]; then
    avg_sentence_len=$(python3 -c "print(round(${word_count}/${sentence_count},1))" 2>/dev/null || echo 0)
    if python3 -c "exit(0 if float('${avg_sentence_len}') <= 20 else 1)" 2>/dev/null; then
      add_finding "PASS" "readme" "Reading level: avg ${avg_sentence_len} words/sentence (accessible)"
    elif python3 -c "exit(0 if float('${avg_sentence_len}') <= 30 else 1)" 2>/dev/null; then
      add_finding "WARNING" "readme" "Reading level: avg ${avg_sentence_len} words/sentence (consider shorter sentences)"
    else
      add_finding "WARNING" "readme" "Reading level: avg ${avg_sentence_len} words/sentence (high — may be hard to follow with a screen reader)"
    fi
  fi

  # Missing H1
  if ! grep -q "^# " "$readme_path"; then
    add_finding "ERROR" "readme" "No H1 heading found — screen readers use H1 as the page title"
  else
    add_finding "PASS" "readme" "H1 heading present"
  fi

  add_finding "PASS" "readme" "README.md scanned (${line_count} lines)"
}

# ── 3. WCAG HTML scan (pa11y) ─────────────────────────────────────────────────

run_wcag_scan() {
  info "── WCAG HTML scan"

  if [[ "$WCAG_ENABLED" != "true" ]]; then
    skip "pa11y not available — skipping WCAG HTML scan"
    skip "Install with: npm install -g pa11y"
    return
  fi

  local docs_dir="${REPO_DIR}/DOCS/generated"
  if [[ ! -d "$docs_dir" ]]; then
    skip "No DOCS/generated/ directory — skipping WCAG HTML scan"
    return
  fi

  local html_files
  mapfile -t html_files < <(find "$docs_dir" -name "*.html" 2>/dev/null)
  if [[ "${#html_files[@]}" -eq 0 ]]; then
    skip "No HTML files in DOCS/generated/ — skipping WCAG HTML scan"
    return
  fi

  local total_issues=0
  for html_file in "${html_files[@]}"; do
    local pa11y_out
    pa11y_out=$(pa11y --standard WCAG2AA --reporter json "$html_file" 2>/dev/null || echo "[]")
    local issue_count
    issue_count=$(echo "$pa11y_out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    (( total_issues += issue_count )) || true
    if [[ "$issue_count" -gt 0 ]]; then
      local issues_summary
      issues_summary=$(echo "$pa11y_out" | python3 -c "
import sys,json
issues=json.load(sys.stdin)
for i in issues[:3]:
    print(f\"  [{i.get('type','?').upper()}] {i.get('message','')[:100]}\")
" 2>/dev/null || true)
      add_finding "WARNING" "wcag" "${issue_count} WCAG 2.1 AA issue(s) in $(basename "$html_file")" \
        "$issues_summary"
    fi
  done

  if [[ "$total_issues" -eq 0 ]]; then
    add_finding "PASS" "wcag" "WCAG 2.1 AA — no issues found in ${#html_files[@]} HTML file(s)"
  fi
}

# ── 4. Audio overview (espeak-ng) ─────────────────────────────────────────────

run_audio_overview() {
  info "── Audio overview"

  if [[ "$AUDIO_ENABLED" != "true" ]]; then
    skip "espeak-ng not available — skipping audio overview"
    skip "Install with: sudo apt-get install espeak-ng ffmpeg"
    return
  fi

  local readme_path="${REPO_DIR}/README.md"
  if [[ ! -f "$readme_path" ]]; then
    skip "No README.md — skipping audio overview"
    return
  fi

  local audio_out="${OUTPUT_DIR}/README.audio.mp3"
  local wav_tmp
  wav_tmp=$(mktemp --suffix=.wav)
  trap 'rm -f "$wav_tmp"' RETURN

  # Strip markdown syntax for cleaner TTS output
  local plain_text
  plain_text=$(cat "$readme_path" \
    | sed 's/```[^`]*```//g' \
    | sed 's/`[^`]*`//g' \
    | sed 's/!\[.*\]([^)]*)/image/g' \
    | sed 's/\[([^]]*)\]([^)]*)/\1/g' \
    | sed 's/[#*_>|]//g' \
    | sed 's/<!--.*-->//g' \
    | grep -v '^\s*$' \
    | head -200)

  info "  Generating speech with espeak-ng..."
  if espeak-ng \
    --ipa \
    -v en \
    -s 150 \
    -w "$wav_tmp" \
    "$plain_text" 2>/dev/null; then

    if command -v ffmpeg &>/dev/null; then
      ffmpeg -y -i "$wav_tmp" -codec:a libmp3lame -qscale:a 4 "$audio_out" \
        -loglevel error 2>/dev/null
      local size_kb
      size_kb=$(du -k "$audio_out" | cut -f1)
      add_finding "PASS" "audio" "Audio overview generated: README.audio.mp3 (${size_kb}KB)"
      info "  Written: ${audio_out}"
    else
      # No ffmpeg — keep WAV
      cp "$wav_tmp" "${OUTPUT_DIR}/README.audio.wav"
      add_finding "PASS" "audio" "Audio overview generated: README.audio.wav (install ffmpeg for MP3)"
    fi
  else
    add_finding "WARNING" "audio" "espeak-ng failed to generate audio overview"
  fi
}

# ── 5. Braille output (liblouis) ──────────────────────────────────────────────

run_braille_output() {
  info "── Braille output"

  if [[ "$BRAILLE_ENABLED" != "true" ]]; then
    skip "python3-louis (liblouis) not available — skipping Braille output"
    skip "Install with: sudo apt-get install python3-louis"
    return
  fi

  local readme_path="${REPO_DIR}/README.md"
  if [[ ! -f "$readme_path" ]]; then
    skip "No README.md — skipping Braille output"
    return
  fi

  local braille_out="${OUTPUT_DIR}/README.brl"

  python3 - "$readme_path" "$braille_out" << 'PYEOF'
import sys
import re

try:
    import louis
except ImportError:
    print("python3-louis not available", file=sys.stderr)
    sys.exit(1)

readme_path = sys.argv[1]
output_path = sys.argv[2]

with open(readme_path) as f:
    content = f.read()

# Strip markdown for cleaner Braille output
content = re.sub(r'```[\s\S]*?```', '', content)
content = re.sub(r'`[^`]+`', '', content)
content = re.sub(r'!\[.*?\]\(.*?\)', '', content)
content = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', content)
content = re.sub(r'<!--.*?-->', '', content, flags=re.DOTALL)
content = re.sub(r'[#*_>|]', '', content)
content = re.sub(r'\n{3,}', '\n\n', content)
content = content.strip()

# Translate to Braille Grade 2 English using liblouis
# Table: en-ueb-g2.ctb = Unified English Braille Grade 2
try:
    braille = louis.translateString(
        ["en-ueb-g2.ctb"],
        content,
        typeform=None,
        spacing=None,
        outputPos=None,
        inputPos=None,
        cursorPos=None,
        mode=0
    )
except Exception:
    # Fallback to Grade 1 if Grade 2 table unavailable
    try:
        braille = louis.translateString(
            ["en-ueb-g1.ctb"],
            content,
            typeform=None,
            spacing=None,
            outputPos=None,
            inputPos=None,
            cursorPos=None,
            mode=0
        )
    except Exception as e:
        print(f"Braille translation failed: {e}", file=sys.stderr)
        sys.exit(1)

with open(output_path, 'w', encoding='utf-8') as f:
    f.write(braille)

print(f"Written {len(braille)} Braille characters to {output_path}")
PYEOF

  if [[ $? -eq 0 && -f "$braille_out" ]]; then
    local char_count
    char_count=$(wc -c < "$braille_out")
    add_finding "PASS" "braille" "Braille Grade 2 output generated: README.brl (${char_count} chars)"
    info "  Written: ${braille_out}"
  else
    add_finding "WARNING" "braille" "Braille translation failed — check liblouis tables are installed"
  fi
}

# ── Write JSON report ─────────────────────────────────────────────────────────

write_report() {
  local report_path="${OUTPUT_DIR}/accessibility-report.json"

  # Build findings JSON array
  local findings_json="["
  local first=true
  for f in "${FINDINGS[@]}"; do
    $first || findings_json+=","
    findings_json+="$f"
    first=false
  done
  findings_json+="]"

  python3 - "$report_path" "$findings_json" << PYEOF
import sys, json, datetime

report_path   = sys.argv[1]
findings_json = sys.argv[2]

findings = json.loads(findings_json)

report = {
    "repo":       "${OWNER}/${REPO}",
    "generated":  datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "summary": {
        "errors":   ${errors},
        "warnings": ${warnings},
        "passes":   ${passes},
        "audio_generated":   "${AUDIO_ENABLED}" == "true",
        "braille_generated": "${BRAILLE_ENABLED}" == "true",
    },
    "findings": findings,
}

with open(report_path, "w") as f:
    json.dump(report, f, indent=2)

print(f"Report written: {report_path}")
PYEOF

  info "  Report: ${report_path}"
}

# ── GitHub Step Summary ───────────────────────────────────────────────────────

write_step_summary() {
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return

  local status_icon="✅"
  [[ "$warnings" -gt 0 ]] && status_icon="⚠️"
  [[ "$errors"   -gt 0 ]] && status_icon="❌"

  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY
## ${status_icon} Accessibility Report — ${OWNER}/${REPO}

| Metric | Value |
|---|---|
| ✅ Passes | ${passes} |
| ⚠️ Warnings | ${warnings} |
| ❌ Errors | ${errors} |
| 🔊 Audio overview | $([ "$AUDIO_ENABLED" = "true" ] && echo "Generated (README.audio.mp3)" || echo "Not available (install espeak-ng)") |
| ⠃⠗⠇ Braille output | $([ "$BRAILLE_ENABLED" = "true" ] && echo "Generated (README.brl)" || echo "Not available (install python3-louis)") |

SUMMARY

  if [[ "${#FINDINGS[@]}" -gt 0 ]]; then
    echo "### Findings" >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
    for f in "${FINDINGS[@]}"; do
      local level msg cat
      level=$(echo "$f" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['level'])" 2>/dev/null)
      cat=$(echo "$f"   | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['category'])" 2>/dev/null)
      msg=$(echo "$f"   | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['message'])" 2>/dev/null)
      local icon="✅"
      [[ "$level" == "WARNING" ]] && icon="⚠️"
      [[ "$level" == "ERROR"   ]] && icon="❌"
      echo "- ${icon} **[${cat}]** ${msg}" >> "$GITHUB_STEP_SUMMARY"
    done
    echo "" >> "$GITHUB_STEP_SUMMARY"
  fi

  # Reference links
  cat >> "$GITHUB_STEP_SUMMARY" << REFS
### References
- [WCAG 2.1 AA Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
- [GitHub ReadME Project — Accessibility](https://github.com/readme/topics/accessibility)
- [NVDA Screen Reader](https://github.com/nvaccess/nvda)
- [github-codeowners](https://github.com/Interested-Deving-1896/github-codeowners)
REFS
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  info "Starting accessibility audit for ${OWNER}/${REPO}"
  info "Repo dir: ${REPO_DIR}"
  info "Audio: ${AUDIO_ENABLED} | Braille: ${BRAILLE_ENABLED} | WCAG: ${WCAG_ENABLED}"
  echo "" >&2

  run_codeowners_audit
  echo "" >&2
  run_readme_scan
  echo "" >&2
  run_wcag_scan
  echo "" >&2
  run_audio_overview
  echo "" >&2
  run_braille_output
  echo "" >&2

  write_report
  write_step_summary

  echo "" >&2
  echo "════════════════════════════════════════════" >&2
  echo "  Accessibility audit complete" >&2
  echo "  ✅ Passes  : ${passes}" >&2
  echo "  ⚠️  Warnings: ${warnings}" >&2
  echo "  ❌ Errors  : ${errors}" >&2
  echo "════════════════════════════════════════════" >&2

  if [[ "$FAIL_ON_ERROR" == "true" && "$errors" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main
