#!/usr/bin/env bash
# adapters/pandoc.sh — Pandoc PDF + EPUB export adapter
set -euo pipefail
info() { echo "[book-engine:pandoc] $*" >&2; }

# Install pandoc
if ! command -v pandoc &>/dev/null; then
    info "Installing pandoc..."
    apt-get install -y pandoc texlive-latex-base texlive-fonts-recommended 2>/dev/null || \
    brew install pandoc 2>/dev/null || \
    { echo "[book-engine:pandoc] Cannot install pandoc" >&2; exit 1; }
fi

# Get ordered file list from SUMMARY.md
FILES=$(python3 vendor/book-engine/scripts/summary_to_nav.py \
    --format filelist \
    --summary "${BOOK_SRC}/SUMMARY.md" \
    --src-dir "${BOOK_SRC}")

mkdir -p "${BOOK_OUT}"

# PDF
info "Building PDF..."
# shellcheck disable=SC2086
pandoc --from markdown+smart \
    --to pdf \
    --metadata title="${BOOK_TITLE}" \
    --metadata author="Interested-Deving-1896" \
    --variable geometry:margin=1in \
    --variable fontsize=11pt \
    --variable colorlinks=true \
    --variable linkcolor=NavyBlue \
    --toc --toc-depth=3 \
    --output "${BOOK_OUT}/book.pdf" \
    ${FILES} 2>/dev/null || info "PDF build failed (LaTeX may be missing)"

# EPUB
info "Building EPUB..."
# shellcheck disable=SC2086
pandoc --from markdown+smart \
    --to epub3 \
    --metadata title="${BOOK_TITLE}" \
    --metadata author="Interested-Deving-1896" \
    --toc --toc-depth=3 \
    --output "${BOOK_OUT}/book.epub" \
    ${FILES} 2>/dev/null || info "EPUB build failed"

info "Pandoc output: ${BOOK_OUT}/book.pdf + ${BOOK_OUT}/book.epub"
