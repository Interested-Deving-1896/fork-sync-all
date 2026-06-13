#!/usr/bin/env bash
# test-check-readme-render-mobile.sh — verify mobile/cross-engine checks 13-22
# Each test creates a minimal README, runs the checker, and asserts the expected
# warning text appears (or doesn't appear for the clean case).

set -uo pipefail

SCRIPT="$(dirname "$0")/../check-readme-render.sh"
PASS=0
FAIL=0
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Minimal valid README header used by every test
HEADER='# Test Repo

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/test/repo)

'

run_test() {
  local name="$1"
  local body="$2"
  local expect_pattern="$3"   # grep -F string; empty = expect clean pass
  local expect_clean="${4:-false}"

  local tmp="${TMPDIR_BASE}/${name}.md"
  printf '%s%s\n' "$HEADER" "$body" > "$tmp"

  local output
  output=$(bash "$SCRIPT" "$tmp" 2>/dev/null)

  if [[ "$expect_clean" == "true" ]]; then
    if echo "$output" | grep -q "no issues found"; then
      echo "  PASS: ${name}"
      (( PASS++ )) || true
    else
      echo "  FAIL: ${name} — expected clean, got:"
      echo "        $output"
      (( FAIL++ )) || true
    fi
  else
    if echo "$output" | grep -qF "$expect_pattern"; then
      echo "  PASS: ${name}"
      (( PASS++ )) || true
    else
      echo "  FAIL: ${name} — expected pattern not found: '${expect_pattern}'"
      echo "        actual output: $output"
      (( FAIL++ )) || true
    fi
  fi
}

echo "=== Mobile/cross-engine rendering checks ==="
echo ""

# ── Check 13: <img align="..."> ───────────────────────────────────────────────
run_test "13-img-align-detected" \
  '<img align="right" src="https://raw.githubusercontent.com/test/repo/main/logo.png" alt="logo">' \
  "align attribute stripped by GFM"

run_test "13-img-no-align-clean" \
  '<img src="https://raw.githubusercontent.com/test/repo/main/logo.png" alt="logo">' \
  "" "true"

# ── Check 14: <img> missing alt ───────────────────────────────────────────────
run_test "14-img-no-alt-detected" \
  '<img src="https://raw.githubusercontent.com/test/repo/main/logo.png">' \
  "missing alt attribute"

run_test "14-img-with-alt-clean" \
  '<img src="https://raw.githubusercontent.com/test/repo/main/logo.png" alt="logo">' \
  "" "true"

# ── Check 15: uppercase extension in <img src> ────────────────────────────────
run_test "15-img-src-uppercase-ext-detected" \
  '<img src="https://raw.githubusercontent.com/test/repo/main/logo.PNG" alt="logo">' \
  "uppercase extension .PNG"

run_test "15-img-src-lowercase-ext-clean" \
  '<img src="https://raw.githubusercontent.com/test/repo/main/logo.png" alt="logo">' \
  "" "true"

# ── Check 23: uppercase extension in markdown image syntax ───────────────────
run_test "23-md-img-uppercase-ext-detected" \
  '![logo](https://raw.githubusercontent.com/test/repo/main/logo.PNG)' \
  "uppercase extension .PNG"

run_test "23-md-img-lowercase-ext-clean" \
  '![logo](https://raw.githubusercontent.com/test/repo/main/logo.png)' \
  "" "true"

# ── Check 16: unencoded space in image URL ────────────────────────────────────
run_test "16-img-url-space-detected" \
  '![logo](https://raw.githubusercontent.com/test/repo/main/my logo.png)' \
  "unencoded space"

run_test "16-img-url-encoded-space-clean" \
  '![logo](https://raw.githubusercontent.com/test/repo/main/my%20logo.png)' \
  "" "true"

# ── Check 17: <div> layout blocks ────────────────────────────────────────────
run_test "17-div-detected" \
  '<div align="center">some content</div>' \
  "stripped by GFM sanitiser"

run_test "17-no-div-clean" \
  'Some plain paragraph text.' \
  "" "true"

# ── Check 18: <kbd>/<sub>/<sup> in table cells ────────────────────────────────
run_test "18-kbd-in-table-detected" \
  '| Key | Action |
|-----|--------|
| <kbd>Ctrl+C</kbd> | Copy |' \
  "inside table cell"

run_test "18-kbd-outside-table-clean" \
  'Press <kbd>Ctrl+C</kbd> to copy.' \
  "" "true"

# ── Check 19: wide table (> 5 columns) ───────────────────────────────────────
run_test "19-wide-table-detected" \
  '| A | B | C | D | E | F |
|---|---|---|---|---|---|
| 1 | 2 | 3 | 4 | 5 | 6 |' \
  "overflows on mobile"

run_test "19-narrow-table-clean" \
  '| A | B | C |
|---|---|---|
| 1 | 2 | 3 |' \
  "" "true"

# ── Check 20: very long line ──────────────────────────────────────────────────
LONG_LINE=$(python3 -c "print('x' * 501)")
run_test "20-long-line-detected" \
  "$LONG_LINE" \
  "mobile parser memory pressure"

SHORT_LINE=$(python3 -c "print('x' * 100)")
run_test "20-short-line-clean" \
  "$SHORT_LINE" \
  "" "true"

# ── Check 21: deeply nested <details> ────────────────────────────────────────
run_test "21-deep-details-detected" \
  '<details><summary>L1</summary>
<details><summary>L2</summary>
<details><summary>L3</summary>
deep content
</details>
</details>
</details>' \
  "nested 3 levels deep"

run_test "21-shallow-details-clean" \
  '<details><summary>L1</summary>
<details><summary>L2</summary>
content
</details>
</details>' \
  "" "true"

# ── Check 22: untrusted image host ───────────────────────────────────────────
run_test "22-untrusted-host-detected" \
  '![logo](https://example.com/logo.png)' \
  "untrusted host"

run_test "22-trusted-host-raw-clean" \
  '![logo](https://raw.githubusercontent.com/test/repo/main/logo.png)' \
  "" "true"

run_test "22-trusted-host-shields-clean" \
  '![build](https://img.shields.io/badge/build-passing-green)' \
  "" "true"

run_test "22-trusted-host-ona-clean" \
  '[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/test/repo)' \
  "" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 )) && exit 0 || exit 1
