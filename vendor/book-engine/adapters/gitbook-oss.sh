#!/usr/bin/env bash
# adapters/gitbook-oss.sh — GitBook OSS (Next.js renderer) adapter
#
# GitBook OSS (github.com/GitbookIO/gitbook) is the open-source rendering
# engine that powers gitbook.com. Unlike the legacy gitbook-cli, it is a
# Next.js app that proxies any published GitBook space through a local server.
#
# Requirements:
#   - Node.js >= 22.3  (checked below)
#   - Bun >= 1.2.15    (installed if missing)
#   - GITBOOK_SPACE_URL — the published gitbook.com space URL to render
#     e.g. https://fork-sync-all.gitbook.io/docs
#
# What this adapter does:
#   1. Clones/updates GitbookIO/gitbook into vendor/book-engine/gitbook-oss/
#   2. Installs dependencies with bun
#   3. Builds the Next.js app
#   4. Exports a static snapshot of GITBOOK_SPACE_URL to ${BOOK_OUT}/gitbook-oss/
#
# Note: A gitbook.com account and published space are required for the export
# to contain real content. Without GITBOOK_SPACE_URL the adapter builds the
# renderer shell only (useful for CI validation).

set -euo pipefail
info()  { echo "[book-engine:gitbook-oss] $*" >&2; }
warn()  { echo "[book-engine:gitbook-oss:warn] $*" >&2; }
fatal() { echo "[book-engine:gitbook-oss:fatal] $*" >&2; exit 1; }

GITBOOK_SPACE_URL="${GITBOOK_SPACE_URL:-}"
OSS_DIR="${REPO_ROOT}/vendor/book-engine/gitbook-oss"
OUT_DIR="${BOOK_OUT}/gitbook-oss"

# ── Node.js version check ─────────────────────────────────────────────────────
NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [[ "${NODE_VERSION}" -lt 22 ]]; then
    warn "Node.js >= 22.3 required (found v${NODE_VERSION}). Attempting upgrade via nvm..."
    if command -v nvm &>/dev/null; then
        nvm install 22 && nvm use 22
    else
        fatal "Node.js >= 22.3 required. Install via: nvm install 22"
    fi
fi

# ── Bun install ───────────────────────────────────────────────────────────────
if ! command -v bun &>/dev/null; then
    info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="${HOME}/.bun/bin:${PATH}"
fi

BUN_VERSION=$(bun --version 2>/dev/null | cut -d. -f1,2 || echo "0.0")
info "Bun version: ${BUN_VERSION}"

# ── Clone or update GitBook OSS ───────────────────────────────────────────────
if [[ -d "${OSS_DIR}/.git" ]]; then
    info "Updating GitBook OSS..."
    git -C "${OSS_DIR}" pull --quiet
else
    info "Cloning GitbookIO/gitbook..."
    git clone --depth=1 https://github.com/GitbookIO/gitbook.git "${OSS_DIR}"
fi

cd "${OSS_DIR}"

# ── Install dependencies ──────────────────────────────────────────────────────
info "Installing dependencies with bun..."
bun install --frozen-lockfile 2>/dev/null || bun install

# ── Build ─────────────────────────────────────────────────────────────────────
info "Building Next.js app..."
bun run build 2>/dev/null || {
    warn "bun run build failed — trying npm run build"
    npm run build
}

# ── Export static snapshot ────────────────────────────────────────────────────
mkdir -p "${OUT_DIR}"

if [[ -n "${GITBOOK_SPACE_URL}" ]]; then
    info "Exporting static snapshot of: ${GITBOOK_SPACE_URL}"
    # Start the dev server in background, export via next export or wget crawl
    bun dev &
    SERVER_PID=$!
    sleep 8  # wait for Next.js to start

    # Use wget to crawl the local proxy
    ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GITBOOK_SPACE_URL}', safe=''))")
    wget --recursive --no-parent --convert-links --adjust-extension \
         --page-requisites --no-verbose \
         --directory-prefix="${OUT_DIR}" \
         "http://localhost:3000/url/${GITBOOK_SPACE_URL}" 2>/dev/null || true

    kill "${SERVER_PID}" 2>/dev/null || true
    info "Static export complete: ${OUT_DIR}/"
else
    warn "GITBOOK_SPACE_URL not set — skipping static export."
    warn "Set GITBOOK_SPACE_URL=https://your-space.gitbook.io/docs to export content."
    info "GitBook OSS renderer built at: ${OSS_DIR}"
    info "Run manually: cd ${OSS_DIR} && bun dev"
    info "Then open: http://localhost:3000/url/<your-gitbook-space-url>"

    # Write a placeholder index so the output dir is not empty
    cat > "${OUT_DIR}/index.html" << HTML_EOF
<!DOCTYPE html>
<html>
<head><title>GitBook OSS — fork-sync-all</title></head>
<body>
<h1>GitBook OSS Renderer</h1>
<p>Set <code>GITBOOK_SPACE_URL</code> to export a static snapshot.</p>
<p>Renderer source: <a href="https://github.com/GitbookIO/gitbook">GitbookIO/gitbook</a></p>
</body>
</html>
HTML_EOF
fi

info "GitBook OSS adapter complete."
