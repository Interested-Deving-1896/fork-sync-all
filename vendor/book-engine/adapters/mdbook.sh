#!/usr/bin/env bash
# adapters/mdbook.sh — mdBook build adapter
set -euo pipefail
info() { echo "[book-engine:mdbook] $*" >&2; }

# Install mdBook if not present
if ! command -v mdbook &>/dev/null; then
    info "Installing mdBook 0.4.40..."
    cargo install mdbook --version 0.4.40 --locked 2>/dev/null || {
        # Fallback: download pre-built binary
        OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
        ARCH="$(uname -m)"
        [[ "${ARCH}" == "x86_64" ]] && ARCH="x86_64-unknown-linux-gnu"
        URL="https://github.com/rust-lang/mdBook/releases/download/v0.4.40/mdbook-v0.4.40-${ARCH}.tar.gz"
        curl -sL "${URL}" | tar -xz -C /usr/local/bin/ mdbook 2>/dev/null || true
    }
fi

# Apply FSA theme to book.toml if not already present
if ! grep -q "additional-css" book.toml 2>/dev/null; then
    info "Injecting FSA theme into book.toml"
    cat >> book.toml << 'TOML_EOF'

[output.html]
additional-css = ["vendor/book-engine/themes/fsa/custom.css"]
additional-js  = ["vendor/book-engine/themes/fsa/book.js"]
git-repository-url = "https://github.com/Interested-Deving-1896/fork-sync-all"
git-repository-icon = "fa-github"
edit-url-template = "https://github.com/Interested-Deving-1896/fork-sync-all/edit/main/{path}"
TOML_EOF
fi

# Stage README + AGENTS into DOCS/ (same as deploy-book.yml)
[[ -f README.md ]] && cp README.md "${BOOK_SRC}/README.md"
[[ -f AGENTS.md ]] && cp AGENTS.md "${BOOK_SRC}/AGENTS.md"

info "Running: mdbook build --dest-dir ${BOOK_OUT}"
mdbook build --dest-dir "${BOOK_OUT}"
info "mdBook output: ${BOOK_OUT}/"
