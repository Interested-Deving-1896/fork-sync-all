#!/usr/bin/env bash
#
# Generates a dependency graph of the OSP stack by reading ## Origins sections
# from all OSP-bound Interested-Deving-1896 repos.
#
# Outputs three artefacts to OUTPUT_DIR (default: dep-graph/):
#
#   origins.json      — machine-readable map of repo → [origin, ...]
#   origins.md        — human-readable Markdown table
#   origins.dot       — Graphviz DOT file for visual rendering
#
# Each origin entry records:
#   - host (github | kde | gitlab | internal)
#   - slug (owner/repo)
#   - url  (canonical upstream URL)
#   - fork_exists (true/false — whether I-D-1896 has a fork)
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with repo read scope
#   GITHUB_OWNER  — org to scan (default: Interested-Deving-1896)
#
# Optional env vars:
#   OUTPUT_DIR    — directory to write artefacts (default: dep-graph)
#   PUSH_TO_REPO  — set to "true" to commit artefacts back to fork-sync-all

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
OUTPUT_DIR="${OUTPUT_DIR:-dep-graph}"
PUSH_TO_REPO="${PUSH_TO_REPO:-false}"

GH_API="https://api.github.com"
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

info() { echo "[generate-dep-graph] $*"; }
warn() { echo "[warn] $*" >&2; }

# ── OSP-bound repo list (from sync-to-gitlab.sh) ─────────────────────────────

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

get_readme_text() {
  local repo="$1"
  for branch in main master develop; do
    local info content
    info=$(gh_api GET "${GH_API}/repos/${GITHUB_OWNER}/${repo}/contents/README.md?ref=${branch}" 2>/dev/null) || continue
    content=$(echo "$info" | python3 -c \
      "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d.get('content','')).decode('utf-8','replace'))" \
      2>/dev/null) || continue
    [[ -n "$content" ]] && echo "$content" && return 0
  done
  return 1
}

fork_exists() {
  local name="$1"
  local info
  info=$(gh_api GET "${GH_API}/repos/${GITHUB_OWNER}/${name}" 2>/dev/null) || return 1
  echo "$info" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('name') else 1)" 2>/dev/null
}

# ── Origins parser (mirrors sync-upstream-sources.sh logic) ──────────────────

parse_origins() {
  local readme="$1"
  local origins_block
  origins_block=$(echo "$readme" | awk '/^## Origins/{f=1;next} f && /^## /{exit} f{print}')
  [[ -z "$origins_block" ]] && return 0

  # GitHub
  echo "$origins_block" \
    | grep -oP 'https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://github.com/||' \
    | sort -u \
    | while read -r slug; do
        if echo "$slug" | grep -qi "^${GITHUB_OWNER}/"; then
          echo "internal|${slug}|https://github.com/${slug}"
        else
          echo "github|${slug}|https://github.com/${slug}"
        fi
      done

  # KDE Invent
  echo "$origins_block" \
    | grep -oP 'https://invent\.kde\.org/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://invent.kde.org/||' \
    | sort -u \
    | while read -r slug; do echo "kde|${slug}|https://invent.kde.org/${slug}"; done

  # GitLab.com (non-openos-project)
  echo "$origins_block" \
    | grep -oP 'https://gitlab\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' \
    | sed 's|https://gitlab.com/||' \
    | grep -iv "^openos-project/" \
    | sort -u \
    | while read -r slug; do echo "gitlab|${slug}|https://gitlab.com/${slug}"; done
}

# ── Main ──────────────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

info "Scanning ${#OSP_REPOS[@]} OSP-bound repos..."
echo ""

# Collect all data into a temp JSON builder
json_entries="[]"
md_rows=""
dot_edges=""

repos_with_origins=0
repos_without_origins=0
total_origins=0
declare -A seen_slugs  # for dedup in DOT/summary

for repo in "${OSP_REPOS[@]}"; do
  info "── ${repo}"

  readme=$(get_readme_text "$repo") || {
    warn "  No README — skipping"
    (( repos_without_origins++ )) || true
    continue
  }

  if ! echo "$readme" | grep -q "^## Origins"; then
    info "  No Origins section (run patch-origins-sections.sh first)"
    (( repos_without_origins++ )) || true
    continue
  fi

  (( repos_with_origins++ )) || true

  repo_origins="[]"

  while IFS='|' read -r host slug url; do
    [[ -z "$host" || -z "$slug" ]] && continue

    fork_name="${slug##*/}"
    exists="false"
    if [[ "$host" == "internal" ]]; then
      exists="true"
    elif fork_exists "$fork_name" 2>/dev/null; then
      exists="true"
    fi

    info "  ${host}: ${slug} (fork_exists=${exists})"
    (( total_origins++ )) || true

    # Append to this repo's origins array
    repo_origins=$(python3 -c "
import json
arr = json.loads('''${repo_origins}''')
arr.append({'host': '${host}', 'slug': '${slug}', 'url': '${url}', 'fork_exists': ${exists^}})
print(json.dumps(arr))
")

    # Markdown row
    host_badge=""
    case "$host" in
      github)   host_badge="GitHub" ;;
      kde)      host_badge="KDE Invent" ;;
      gitlab)   host_badge="GitLab" ;;
      internal) host_badge="Internal" ;;
    esac
    fork_col="❌"
    [[ "$exists" == "true" ]] && fork_col="✅"
    md_rows+="| \`${repo}\` | [${slug}](${url}) | ${host_badge} | ${fork_col} |"$'\n'

    # DOT edge (deduplicate external nodes)
    dot_node="${slug//\//__}"
    if [[ "$host" != "internal" ]]; then
      if [[ ! -v seen_slugs["$slug"] ]]; then
        seen_slugs["$slug"]=1
        case "$host" in
          github) dot_edges+="  \"${dot_node}\" [label=\"${slug}\", shape=box, style=filled, fillcolor=\"#ddeeff\"];"$'\n' ;;
          kde)    dot_edges+="  \"${dot_node}\" [label=\"${slug}\", shape=box, style=filled, fillcolor=\"#eeddff\"];"$'\n' ;;
          gitlab) dot_edges+="  \"${dot_node}\" [label=\"${slug}\", shape=box, style=filled, fillcolor=\"#ffeedd\"];"$'\n' ;;
        esac
      fi
      dot_edges+="  \"${repo}\" -> \"${dot_node}\";"$'\n'
    else
      dot_edges+="  \"${repo}\" -> \"${slug##*/}\";"$'\n'
    fi

  done < <(parse_origins "$readme")

  # Append repo entry to master JSON
  json_entries=$(python3 -c "
import json
arr = json.loads('''${json_entries}''')
origins = json.loads('''${repo_origins}''')
arr.append({'repo': '${repo}', 'origins': origins})
print(json.dumps(arr, indent=2))
")

done

# ── Write origins.json ────────────────────────────────────────────────────────

echo "$json_entries" > "${OUTPUT_DIR}/origins.json"
info "Written: ${OUTPUT_DIR}/origins.json"

# ── Write origins.md ──────────────────────────────────────────────────────────

cat > "${OUTPUT_DIR}/origins.md" << MDEOF
# OSP Stack Dependency Graph

Generated: $(date -u '+%Y-%m-%d %H:%M UTC')

| Repo | Origin | Host | Fork in I-D-1896 |
|------|--------|------|-----------------|
${md_rows}

## Summary

- OSP-bound repos scanned: **${#OSP_REPOS[@]}**
- Repos with Origins sections: **${repos_with_origins}**
- Repos missing Origins sections: **${repos_without_origins}** *(run patch-origins-sections.sh)*
- Total origin references: **${total_origins}**
MDEOF
info "Written: ${OUTPUT_DIR}/origins.md"

# ── Write origins.dot ─────────────────────────────────────────────────────────

cat > "${OUTPUT_DIR}/origins.dot" << DOTEOF
digraph osp_origins {
  rankdir=LR;
  node [fontname="Helvetica", fontsize=10];
  edge [fontsize=8];

  // OSP-bound repos (source nodes)
$(for repo in "${OSP_REPOS[@]}"; do
    echo "  \"${repo}\" [shape=ellipse, style=filled, fillcolor=\"#ddffdd\"];"
  done)

  // Edges and external nodes
${dot_edges}
}
DOTEOF
info "Written: ${OUTPUT_DIR}/origins.dot"

# ── Optionally push artefacts back to fork-sync-all ──────────────────────────

if [[ "$PUSH_TO_REPO" == "true" ]]; then
  info "Committing artefacts to fork-sync-all..."
  git config user.email "actions@github.com"
  git config user.name "github-actions[bot]"
  git add "${OUTPUT_DIR}/"
  if git diff --cached --quiet; then
    info "No changes to commit."
  else
    git commit -m "chore: update OSP dependency graph [auto]"
    git push
    info "Pushed."
  fi
fi

echo ""
echo "════════════════════════════════════════════"
echo "  generate-dep-graph complete"
echo "  Repos with Origins : ${repos_with_origins}"
echo "  Repos missing      : ${repos_without_origins}"
echo "  Total origins      : ${total_origins}"
echo "  Output dir         : ${OUTPUT_DIR}/"
echo "════════════════════════════════════════════"
