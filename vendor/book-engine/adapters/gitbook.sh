#!/usr/bin/env bash
# adapters/gitbook.sh — GitBook CLI v3 build adapter
set -euo pipefail
info() { echo "[book-engine:gitbook] $*" >&2; }

# Install GitBook CLI
if ! command -v gitbook &>/dev/null; then
    info "Installing gitbook-cli..."
    npm install -g gitbook-cli@2.3.2 --quiet 2>/dev/null || true
    gitbook fetch 3.2.3 2>/dev/null || true
fi

# GitBook needs a book.json for config
if [[ ! -f "${BOOK_SRC}/book.json" ]]; then
    info "Generating ${BOOK_SRC}/book.json"
    cat > "${BOOK_SRC}/book.json" << JSON_EOF
{
  "title": "${BOOK_TITLE}",
  "description": "Sync and mirror infrastructure for the Interested-Deving-1896 / OpenOS-Project org chain",
  "author": "Interested-Deving-1896",
  "styles": {
    "website": "vendor/book-engine/themes/fsa/gitbook-extra.css"
  },
  "plugins": ["search", "highlight", "sharing"],
  "pluginsConfig": {
    "sharing": {
      "github": true,
      "twitter": false
    }
  }
}
JSON_EOF
fi

mkdir -p "${BOOK_OUT}/gitbook"
info "Running: gitbook build ${BOOK_SRC} ${BOOK_OUT}/gitbook"
gitbook build "${BOOK_SRC}" "${BOOK_OUT}/gitbook" 2>/dev/null || {
    warn "gitbook build failed — GitBook CLI v3 has known Node.js 18+ incompatibilities"
    warn "Consider using the hosted gitbook.com export instead"
    exit 1
}
info "GitBook output: ${BOOK_OUT}/gitbook/"
