#!/usr/bin/env bash
# export.sh — agnostic book export driver
#
# Selects the target engine and delegates to the appropriate adapter.
# All adapters share the same source directory (BOOK_SRC) and output
# root (BOOK_OUT). Each engine writes to its own subdirectory.
#
# Usage:
#   BOOK_ENGINE=mdbook bash vendor/book-engine/scripts/export.sh
#   BOOK_ENGINE=all    bash vendor/book-engine/scripts/export.sh
#   DRY_RUN=true       bash vendor/book-engine/scripts/export.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
BOOK_ENGINE="${BOOK_ENGINE:-mdbook}"
BOOK_SRC="${BOOK_SRC:-DOCS}"
BOOK_OUT="${BOOK_OUT:-book}"
BOOK_TITLE="${BOOK_TITLE:-fork-sync-all}"
BOOK_THEME="${BOOK_THEME:-fsa}"
BOOK_BRAND_DIR="${BOOK_BRAND_DIR:-assets/brand}"
BOOK_LOGO="${BOOK_LOGO:-logo-option-1.png}"
DRY_RUN="${DRY_RUN:-false}"
FSA_API_URL="${FSA_API_URL:-http://localhost:8788}"

ADAPTERS_DIR="${SCRIPT_DIR}/../adapters"
THEMES_DIR="${SCRIPT_DIR}/../themes"

info()  { echo "[book-engine] $*" >&2; }
warn()  { echo "[book-engine:warn] $*" >&2; }
dry()   { echo "[book-engine:dry-run] $*" >&2; }
fatal() { echo "[book-engine:fatal] $*" >&2; exit 1; }

# ── FSA API data injection ────────────────────────────────────────────────────
# Attempt to pull live data from the FSA MCP server to inject into book pages.
# Fails silently — the book builds fine without live data.
inject_fsa_data() {
    if curl -sf --max-time 3 "${FSA_API_URL}/health" >/dev/null 2>&1; then
        info "FSA API reachable at ${FSA_API_URL} — injecting live data"
        # Fetch quota snapshot for the book cover/status page
        curl -sf --max-time 10 "${FSA_API_URL}/sse" \
            -H "Content-Type: application/json" \
            -d '{"method":"tools/call","params":{"name":"get_config_summary","arguments":{}}}' \
            > "${BOOK_SRC}/.fsa-live-data.json" 2>/dev/null || true
    else
        info "FSA API not reachable — building without live data"
    fi
}

# ── SUMMARY.md → nav format converters ───────────────────────────────────────
generate_mkdocs_nav() {
    python3 "${SCRIPT_DIR}/summary_to_nav.py" \
        --format mkdocs \
        --summary "${BOOK_SRC}/SUMMARY.md" \
        --title "${BOOK_TITLE}" \
        --theme-dir "${THEMES_DIR}/${BOOK_THEME}" \
        --logo "${BOOK_BRAND_DIR}/${BOOK_LOGO}" \
        > mkdocs.yml
    info "Generated mkdocs.yml from SUMMARY.md"
}

generate_docusaurus_sidebar() {
    python3 "${SCRIPT_DIR}/summary_to_nav.py" \
        --format docusaurus \
        --summary "${BOOK_SRC}/SUMMARY.md" \
        > sidebars.js
    info "Generated sidebars.js from SUMMARY.md"
}

# ── Engine dispatch ───────────────────────────────────────────────────────────
run_engine() {
    local engine="$1"
    local adapter="${ADAPTERS_DIR}/${engine}.sh"

    [[ -f "${adapter}" ]] || fatal "No adapter found for engine '${engine}' at ${adapter}"

    info "Building with engine: ${engine}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        dry "Would run: bash ${adapter}"
        dry "  BOOK_SRC=${BOOK_SRC} BOOK_OUT=${BOOK_OUT} BOOK_TITLE=${BOOK_TITLE}"
        return 0
    fi

    # Pre-build: inject FSA live data
    inject_fsa_data

    # Pre-build: generate engine-specific nav if needed
    case "${engine}" in
        mkdocs)     generate_mkdocs_nav ;;
        docusaurus) generate_docusaurus_sidebar ;;
    esac

    # Run the adapter
    export BOOK_SRC BOOK_OUT BOOK_TITLE BOOK_THEME BOOK_BRAND_DIR BOOK_LOGO \
           THEMES_DIR ADAPTERS_DIR REPO_ROOT FSA_API_URL
    bash "${adapter}"

    info "Engine '${engine}' build complete → ${BOOK_OUT}/"
}

# ── Main ──────────────────────────────────────────────────────────────────────
cd "${REPO_ROOT}"

if [[ "${BOOK_ENGINE}" == "all" ]]; then
    info "Building all engines"
    for adapter in "${ADAPTERS_DIR}"/*.sh; do
        engine="$(basename "${adapter}" .sh)"
        run_engine "${engine}" || warn "Engine '${engine}' failed — continuing"
    done
else
    run_engine "${BOOK_ENGINE}"
fi

info "Done."
