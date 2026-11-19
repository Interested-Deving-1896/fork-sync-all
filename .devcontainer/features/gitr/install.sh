#!/usr/bin/env bash
# Installs Gitr — a Rust CLI for managing git repos across multiple hosting
# services (GitHub, GitLab, Gitea, Bitbucket, Azure DevOps).
#
# Tries in order:
#   1. Pre-built binary from GitHub Releases (fast, no Rust toolchain needed)
#   2. cargo install --git (build from source; upstream has no crates.io publish)
#
# The VERSION variable is injected by the devcontainer feature runtime.
# Failure is non-fatal — gitr is a convenience tool, not a hard dependency.
#
# NOTE: set -e is intentionally NOT used at the top level so that a failed
# cargo build or network timeout does not abort the entire devcontainer build.
# Individual functions use local error handling instead.
set -uo pipefail

VERSION="${VERSION:-latest}"
INSTALL_DIR="/usr/local/bin"
REPO="crussella0129/Gitr"
REPO_URL="https://github.com/${REPO}.git"

ARCH="$(uname -m)"

# Map uname -m to the target triple used in Gitr release assets
case "$ARCH" in
    x86_64)  RUST_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) RUST_ARCH="aarch64-unknown-linux-musl" ;;
    armv7l)  RUST_ARCH="armv7-unknown-linux-musleabihf" ;;
    *)       RUST_ARCH="" ;;
esac

_install_from_release() {
    local tag="$1"
    [[ -z "$RUST_ARCH" ]] && return 1
    [[ -z "$tag" || "$tag" == "latest" ]] && return 1

    local asset_name="gitr-${RUST_ARCH}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${tag}/${asset_name}"

    echo "Trying release binary: ${url}"
    local tmp
    tmp="$(mktemp -d)"
    if curl -fsSL "$url" -o "${tmp}/gitr.tar.gz" 2>/dev/null; then
        tar -xzf "${tmp}/gitr.tar.gz" -C "$tmp"
        local bin
        bin="$(find "$tmp" -maxdepth 2 -name "gitr" -type f | head -1)"
        if [[ -n "$bin" ]]; then
            install -m 755 "$bin" "${INSTALL_DIR}/gitr"
            rm -rf "$tmp"
            return 0
        fi
    fi
    rm -rf "$tmp"
    return 1
}

_ensure_rust() {
    if ! command -v cargo &>/dev/null; then
        echo "Installing Rust toolchain..."
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
        export PATH="${HOME}/.cargo/bin:${PATH}"
    else
        export PATH="${HOME}/.cargo/bin:${PATH}"
    fi
}

_install_from_git() {
    echo "Building Gitr from source (${REPO_URL})..."
    _ensure_rust

    # Install build dependencies for openssl
    if command -v apt-get &>/dev/null; then
        apt-get install -y --no-install-recommends \
            pkg-config libssl-dev build-essential 2>/dev/null || true
    fi

    cargo install --git "${REPO_URL}" --locked 2>/dev/null \
        || cargo install --git "${REPO_URL}"

    local cargo_bin="${HOME}/.cargo/bin/gitr"
    if [[ -f "$cargo_bin" ]]; then
        install -m 755 "$cargo_bin" "${INSTALL_DIR}/gitr"
        return 0
    fi
    return 1
}

# Resolve version tag
if [[ "$VERSION" == "latest" ]]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || echo "")"
else
    TAG="v${VERSION#v}"
fi

echo "Installing Gitr ${TAG:-from-source} (${ARCH})..."

if _install_from_release "$TAG"; then
    echo "Gitr installed from release binary: $(gitr --version 2>/dev/null || echo "${TAG}")"
elif _install_from_git; then
    echo "Gitr installed from source: $(gitr --version 2>/dev/null || echo "ok")"
else
    echo "WARNING: Gitr installation failed — skipping (non-fatal)"
    exit 0
fi
