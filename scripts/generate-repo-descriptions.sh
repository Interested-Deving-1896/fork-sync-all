#!/usr/bin/env bash
#
# generate-repo-descriptions.sh
#
# AI-powered per-file description generator for GitHub repos.
# Walks a repo's file tree via the GitHub trees API, calls llm_call()
# per file to generate a one-line natural-language description, and
# writes the results to DESCRIPTIONS.md in the repo root.
#
# Inspired by ioncakephper/repo-description — reimplemented using
# fork-sync-all's llm.sh (GitHub Models) + gh-api.sh infrastructure
# instead of Groq + Node.js.
#
# ── Output format ─────────────────────────────────────────────────────────────
#
#   DESCRIPTIONS.md committed to the target repo:
#
#   # File Descriptions
#   <!-- AI:generated -->
#
#   | File | Description |
#   |---|---|
#   | `scripts/sync-forks.sh` | Syncs all upstream forks via the GitHub merge-upstream API |
#   | `config/gitlab-subgroups.yml` | Maps OSP-bound repos to their GitLab subgroup placement |
#   ...
#
# ── Required env vars ─────────────────────────────────────────────────────────
#
#   GH_TOKEN       — PAT with repo + read:org scopes (also used for GitHub Models)
#   GITHUB_OWNER   — org/user owning the target repo
#   TARGET_REPO    — repo name to generate descriptions for
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#
#   MODEL          — GitHub Models model ID (default: openai/gpt-4o-mini)
#                    gpt-4o-mini is preferred here: descriptions are short,
#                    high volume, and don't need frontier reasoning.
#   BRANCH         — branch to read file tree from (default: HEAD)
#   FILE_FILTER    — regex to filter file paths (default: include all non-binary)
#   MAX_FILES      — max files to describe per run (default: 200)
#   SKIP_EXISTING  — if "true", skip files already in DESCRIPTIONS.md (default: true)
#   DRY_RUN        — if "true", print descriptions without committing (default: false)
#   COMMIT_MESSAGE — commit message (default: auto-generated)
#   BUDGET_MINUTES — max runtime in minutes (default: 50)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${TARGET_REPO:?TARGET_REPO is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"
source "${SCRIPT_DIR}/includes/llm.sh"
budget_init

MODEL="${MODEL:-openai/gpt-4o-mini}"
BRANCH="${BRANCH:-HEAD}"
FILE_FILTER="${FILE_FILTER:-}"
MAX_FILES="${MAX_FILES:-200}"
SKIP_EXISTING="${SKIP_EXISTING:-true}"
DRY_RUN="${DRY_RUN:-false}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
BUDGET_MINUTES="${BUDGET_MINUTES:-50}"
GH_API="https://api.github.com"
OUTPUT_FILE="DESCRIPTIONS.md"

info() { echo "[generate-repo-descriptions] $*" >&2; }
warn() { echo "[generate-repo-descriptions][warn] $*" >&2; }
ok()   { echo "[generate-repo-descriptions] ✅ $*" >&2; }
dry()  { echo "[generate-repo-descriptions][dry-run] $*" >&2; }

info "Target: ${GITHUB_OWNER}/${TARGET_REPO} | Branch: ${BRANCH} | Model: ${MODEL}"
info "Max files: ${MAX_FILES} | Skip existing: ${SKIP_EXISTING} | Dry run: ${DRY_RUN}"
echo "" >&2

# ── Fetch file tree ───────────────────────────────────────────────────────────

info "Fetching file tree..."
tree_json=$(gh_get "${GH_API}/repos/${GITHUB_OWNER}/${TARGET_REPO}/git/trees/${BRANCH}?recursive=1" 2>/dev/null) || {
  echo "[generate-repo-descriptions] ❌ Could not fetch file tree for ${GITHUB_OWNER}/${TARGET_REPO}" >&2
  exit 1
}

# Extract blob paths, apply filter, exclude binary-likely extensions
all_paths=$(echo "$tree_json" | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
blobs = [e['path'] for e in data.get('tree', []) if e.get('type') == 'blob']

# Exclude binary / generated / lock files
SKIP_EXTS = {
    '.png','.jpg','.jpeg','.gif','.svg','.ico','.webp','.bmp',
    '.pdf','.zip','.tar','.gz','.bz2','.xz','.7z','.whl','.egg',
    '.pyc','.pyo','.class','.o','.a','.so','.dylib','.dll','.exe',
    '.lock','.sum','.mod',
}
SKIP_NAMES = {'DESCRIPTIONS.md', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml'}
SKIP_DIRS  = {'.git', 'node_modules', 'vendor', '__pycache__', '.venv', 'dist', 'build'}

filter_re = r'${FILE_FILTER}' if r'${FILE_FILTER}' else None

result = []
for p in blobs:
    parts = p.split('/')
    if any(d in SKIP_DIRS for d in parts[:-1]):
        continue
    name = parts[-1]
    if name in SKIP_NAMES:
        continue
    ext = '.' + name.rsplit('.', 1)[-1].lower() if '.' in name else ''
    if ext in SKIP_EXTS:
        continue
    if filter_re and not re.search(filter_re, p):
        continue
    result.append(p)

for p in result:
    print(p)
" 2>/dev/null)

total_paths=$(echo "$all_paths" | grep -c '.' || echo 0)
info "Found ${total_paths} files after filtering"

# ── Load existing descriptions (for skip-existing logic) ─────────────────────

existing_descriptions=()
existing_files_set=""

if [[ "$SKIP_EXISTING" == "true" ]]; then
  existing_raw=$(gh_get "${GH_API}/repos/${GITHUB_OWNER}/${TARGET_REPO}/contents/${OUTPUT_FILE}" 2>/dev/null) || true
  if [[ -n "$existing_raw" ]]; then
    existing_content=$(echo "$existing_raw" | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
print(base64.b64decode(d.get('content','')).decode('utf-8', errors='replace'))
" 2>/dev/null || echo "")
    existing_files_set=$(echo "$existing_content" | grep -oP '(?<=\| `)[^`]+(?=` \|)' | sort || true)
    existing_count=$(echo "$existing_files_set" | grep -c '.' || echo 0)
    info "Found ${existing_count} existing descriptions — will skip those files"
  fi
fi

# ── Filter to files needing descriptions ─────────────────────────────────────

files_to_process=$(echo "$all_paths" | python3 -c "
import sys
all_paths = [l.strip() for l in sys.stdin if l.strip()]
existing  = set('''${existing_files_set}'''.splitlines()) if '${SKIP_EXISTING}' == 'true' else set()
max_files = int('${MAX_FILES}')
result = [p for p in all_paths if p not in existing][:max_files]
for p in result:
    print(p)
" 2>/dev/null)

process_count=$(echo "$files_to_process" | grep -c '.' || echo 0)
info "Files to describe: ${process_count} (capped at ${MAX_FILES})"
echo "" >&2

if [[ "$process_count" -eq 0 ]]; then
  info "Nothing to do — all files already have descriptions."
  exit 0
fi

# ── Generate descriptions ─────────────────────────────────────────────────────

declare -A descriptions=()
generated=0; failed=0

SYSTEM_PROMPT="You are a technical documentation assistant. Given a file path from a software repository, write a single concise sentence (max 15 words) describing what the file does or contains. Be specific and factual. No markdown, no punctuation at the end, no filler phrases like 'This file' or 'Contains'."

while IFS= read -r filepath; do
  [[ -z "$filepath" ]] && continue
  budget_check "$BUDGET_MINUTES" || { warn "Budget exhausted — stopping early."; break; }

  # Fetch a small preview of the file to give the model context
  file_preview=""
  file_raw=$(gh_get "${GH_API}/repos/${GITHUB_OWNER}/${TARGET_REPO}/contents/${filepath}?ref=${BRANCH}" 2>/dev/null) || true
  if [[ -n "$file_raw" ]]; then
    file_preview=$(echo "$file_raw" | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
content = base64.b64decode(d.get('content','')).decode('utf-8', errors='replace')
# First 400 chars is enough context for a one-liner
print(content[:400].replace('\n', ' '))
" 2>/dev/null || echo "")
  fi

  user_prompt="File path: ${filepath}"
  [[ -n "$file_preview" ]] && user_prompt="${user_prompt}
First 400 chars: ${file_preview}"

  description=$(llm_call "$SYSTEM_PROMPT" "$user_prompt" 2>/dev/null) || {
    warn "  LLM call failed for ${filepath} — skipping"
    (( failed++ )) || true
    continue
  }

  # Sanitise: strip leading/trailing whitespace, collapse newlines
  description=$(echo "$description" | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  descriptions["$filepath"]="$description"
  (( generated++ )) || true
  info "  ${filepath}: ${description}"

done <<< "$files_to_process"

echo "" >&2
info "Generated: ${generated} | Failed: ${failed}"

# ── Build DESCRIPTIONS.md ─────────────────────────────────────────────────────

# Merge new descriptions with existing ones
new_content=$(python3 -c "
import json, sys, base64, re

# Existing content
existing_raw = '''${existing_content:-}'''

# New descriptions passed via stdin as JSON
new_descs = json.load(sys.stdin)

# Parse existing table rows
existing_rows = {}
for line in existing_raw.splitlines():
    m = re.match(r'\| \x60(.+?)\x60 \| (.+?) \|', line)
    if m:
        existing_rows[m.group(1)] = m.group(2).strip()

# Merge: new descriptions override existing
merged = {**existing_rows, **new_descs}

# Sort by path
rows = sorted(merged.items())

lines = [
    '# File Descriptions',
    '',
    '<!-- AI:generated -->',
    '<!-- Do not edit manually — regenerated by generate-repo-descriptions.yml -->',
    '',
    '| File | Description |',
    '|---|---|',
]
for path, desc in rows:
    lines.append(f'| \x60{path}\x60 | {desc} |')

print('\n'.join(lines))
" <<< "$(python3 -c "
import json
d = {}
$(for k in "${!descriptions[@]}"; do
    v="${descriptions[$k]//\"/\\\"}"
    echo "d['${k}'] = '${v//\'/\\\'}'"
  done)
print(json.dumps(d))
")" 2>/dev/null)

if [[ -z "$new_content" ]]; then
  warn "Could not build DESCRIPTIONS.md content — aborting"
  exit 1
fi

# ── Commit ────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  dry "Would write DESCRIPTIONS.md (${generated} new descriptions)"
  echo "$new_content" >&2
  exit 0
fi

# Get current file SHA if it exists (needed for update)
current_sha=$(gh_get "${GH_API}/repos/${GITHUB_OWNER}/${TARGET_REPO}/contents/${OUTPUT_FILE}" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

encoded=$(echo "$new_content" | base64 -w 0)
commit_msg="${COMMIT_MESSAGE:-docs(auto): regenerate file descriptions [skip ci]}"

payload=$(python3 -c "
import json, sys
d = {
    'message': '${commit_msg}',
    'content': '${encoded}',
    'branch':  '${BRANCH}' if '${BRANCH}' != 'HEAD' else 'main',
}
sha = '${current_sha}'
if sha:
    d['sha'] = sha
print(json.dumps(d))
" 2>/dev/null)

http=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X PUT \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "${GH_API}/repos/${GITHUB_OWNER}/${TARGET_REPO}/contents/${OUTPUT_FILE}" \
  -d "$payload" 2>/dev/null) || http="000"

if [[ "$http" =~ ^2 ]]; then
  ok "DESCRIPTIONS.md committed to ${GITHUB_OWNER}/${TARGET_REPO} (HTTP ${http})"
else
  warn "Commit failed (HTTP ${http})"
  exit 1
fi

# ── Step summary ──────────────────────────────────────────────────────────────

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY_EOF
## Repo Descriptions — ${GITHUB_OWNER}/${TARGET_REPO}

| Metric | Count |
|---|---|
| Files scanned | ${total_paths} |
| Descriptions generated | ${generated} |
| Failed | ${failed} |

**Model:** \`${MODEL}\` | **Output:** \`${OUTPUT_FILE}\`
SUMMARY_EOF
fi

exit 0
