#!/usr/bin/env bash
# Installs CLIs for all major git hosting platforms.
# Runs inside the devcontainer build context as root.
#
# Platforms covered:
#   gh      — GitHub CLI (cli.github.com)
#   glab    — GitLab CLI (gitlab.com/gitlab-org/cli)
#   tea     — Gitea/Forgejo CLI (gitea.com/gitea/tea)
#   hub     — Legacy GitHub CLI (optional, superseded by gh)
#   bb      — Bitbucket CLI via pip (optional)
#   forgejo — Forgejo CLI (optional, for Forgejo v1.21+)
set -uo pipefail

GH_VERSION="${GH_VERSION:-latest}"
GLAB_VERSION="${GLAB_VERSION:-latest}"
GITEA_VERSION="${GITEA_VERSION:-latest}"
INSTALL_HUB="${INSTALL_HUB:-false}"
INSTALL_BB="${INSTALL_BB:-false}"
INSTALL_FORGEJO_CLI="${INSTALL_FORGEJO_CLI:-false}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_GH="amd64"; ARCH_GLAB="amd64"; ARCH_TEA="amd64" ;;
  aarch64) ARCH_GH="arm64"; ARCH_GLAB="arm64"; ARCH_TEA="arm64" ;;
  armv7l)  ARCH_GH="armv6"; ARCH_GLAB="arm";   ARCH_TEA="arm-6" ;;
  *)       ARCH_GH="amd64"; ARCH_GLAB="amd64"; ARCH_TEA="amd64" ;;
esac

info()  { echo "==> [git-platform-clis] $*"; }
warn()  { echo "==> [git-platform-clis][warn] $*" >&2; }
ok()    { echo "    ✓ $*"; }
skip()  { echo "    - $* (skipped)"; }

# ── Ensure base deps ──────────────────────────────────────────────────────────
info "Ensuring base dependencies..."
apt-get update -qq 2>/dev/null || true
apt-get install -y --no-install-recommends \
  curl wget tar gzip unzip ca-certificates \
  2>/dev/null || true

# ── Helper: resolve 'latest' to a real version tag ───────────────────────────
resolve_gh_release() {
  local repo="$1"
  curl -sf "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
    || echo ""
}

# ── 1. gh — GitHub CLI ───────────────────────────────────────────────────────
info "Installing gh (GitHub CLI)..."
if command -v gh >/dev/null 2>&1 && [[ "$GH_VERSION" == "latest" ]]; then
  ok "gh already installed: $(gh --version 2>/dev/null | head -1)"
else
  # Use the official apt repo for reliable installs
  if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq 2>/dev/null || true
    apt-get install -y gh 2>/dev/null || true
  fi
  if command -v gh >/dev/null 2>&1; then
    ok "gh $(gh --version 2>/dev/null | head -1)"
  else
    warn "gh install failed — skipping"
  fi
fi

# ── 2. glab — GitLab CLI ─────────────────────────────────────────────────────
info "Installing glab (GitLab CLI)..."
if command -v glab >/dev/null 2>&1 && [[ "$GLAB_VERSION" == "latest" ]]; then
  ok "glab already installed: $(glab --version 2>/dev/null | head -1)"
else
  GLAB_TAG="${GLAB_VERSION}"
  if [[ "$GLAB_TAG" == "latest" ]]; then
    GLAB_TAG=$(resolve_gh_release "gitlab-org/cli")
  fi
  if [[ -n "$GLAB_TAG" ]]; then
    GLAB_VER="${GLAB_TAG#v}"
    GLAB_URL="https://gitlab.com/gitlab-org/cli/-/releases/${GLAB_TAG}/downloads/glab_${GLAB_VER}_linux_${ARCH_GLAB}.deb"
    TMP=$(mktemp /tmp/glab.XXXXXX.deb)
    if curl -fsSL "$GLAB_URL" -o "$TMP" 2>/dev/null; then
      dpkg -i "$TMP" 2>/dev/null || apt-get install -f -y 2>/dev/null || true
      rm -f "$TMP"
    else
      # Fallback: binary tarball
      GLAB_URL="https://gitlab.com/gitlab-org/cli/-/releases/${GLAB_TAG}/downloads/glab_${GLAB_VER}_Linux_${ARCH_GLAB}.tar.gz"
      TMP=$(mktemp /tmp/glab.XXXXXX.tar.gz)
      if curl -fsSL "$GLAB_URL" -o "$TMP" 2>/dev/null; then
        tar -xzf "$TMP" -C /usr/local/bin --strip-components=2 "bin/glab" 2>/dev/null \
          || tar -xzf "$TMP" -C /usr/local/bin 2>/dev/null || true
        rm -f "$TMP"
      else
        warn "glab download failed for ${GLAB_TAG} — skipping"
      fi
    fi
  fi
  if command -v glab >/dev/null 2>&1; then
    ok "glab $(glab --version 2>/dev/null | head -1)"
  else
    warn "glab install failed"
  fi
fi

# ── 3. tea — Gitea/Forgejo CLI ───────────────────────────────────────────────
info "Installing tea (Gitea/Forgejo CLI)..."
if command -v tea >/dev/null 2>&1 && [[ "$GITEA_VERSION" == "latest" ]]; then
  ok "tea already installed: $(tea --version 2>/dev/null | head -1)"
else
  TEA_TAG="${GITEA_VERSION}"
  if [[ "$TEA_TAG" == "latest" ]]; then
    TEA_TAG=$(curl -sf "https://gitea.com/api/v1/repos/gitea/tea/releases?limit=1" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['tag_name'] if d else '')" 2>/dev/null || echo "")
  fi
  if [[ -n "$TEA_TAG" ]]; then
    TEA_VER="${TEA_TAG#v}"
    TEA_URL="https://dl.gitea.com/tea/${TEA_VER}/tea-${TEA_VER}-linux-${ARCH_TEA}"
    if curl -fsSL "$TEA_URL" -o /usr/local/bin/tea 2>/dev/null; then
      chmod +x /usr/local/bin/tea
      ok "tea $(tea --version 2>/dev/null | head -1)"
    else
      warn "tea download failed for ${TEA_TAG} — skipping"
    fi
  else
    warn "Could not resolve tea version — skipping"
  fi
fi

# ── 4. hub — Legacy GitHub CLI (optional) ────────────────────────────────────
if [[ "$INSTALL_HUB" == "true" ]]; then
  info "Installing hub (legacy GitHub CLI)..."
  HUB_TAG=$(resolve_gh_release "mislav/hub")
  if [[ -n "$HUB_TAG" ]]; then
    HUB_VER="${HUB_TAG#v}"
    HUB_URL="https://github.com/mislav/hub/releases/download/${HUB_TAG}/hub-linux-${ARCH_GH}-${HUB_VER}.tgz"
    TMP=$(mktemp /tmp/hub.XXXXXX.tgz)
    if curl -fsSL "$HUB_URL" -o "$TMP" 2>/dev/null; then
      tar -xzf "$TMP" -C /tmp 2>/dev/null
      HUB_BIN=$(find /tmp -name 'hub' -type f 2>/dev/null | head -1)
      [[ -n "$HUB_BIN" ]] && mv "$HUB_BIN" /usr/local/bin/hub && chmod +x /usr/local/bin/hub
      rm -f "$TMP"
    fi
  fi
  command -v hub >/dev/null 2>&1 \
    && ok "hub $(hub --version 2>/dev/null | head -1)" \
    || warn "hub install failed"
else
  skip "hub (set install_hub=true to enable)"
fi

# ── 5. bb — Bitbucket CLI (optional) ─────────────────────────────────────────
if [[ "$INSTALL_BB" == "true" ]]; then
  info "Installing bb (Bitbucket CLI)..."
  PIP_BIN=""
  for p in pip3 pip pip3.12 pip3.11; do
    command -v "$p" >/dev/null 2>&1 && PIP_BIN="$p" && break
  done
  if [[ -n "$PIP_BIN" ]]; then
    "$PIP_BIN" install --quiet --break-system-packages "bitbucket-cli" 2>/dev/null \
      || "$PIP_BIN" install --quiet "bitbucket-cli" 2>/dev/null || true
    command -v bb >/dev/null 2>&1 \
      && ok "bb installed" \
      || warn "bb install failed — try: pip install bitbucket-cli"
  else
    warn "pip not available — cannot install bb"
  fi
else
  skip "bb (set install_bb=true to enable)"
fi

# ── 6. forgejo-cli (optional) ────────────────────────────────────────────────
if [[ "$INSTALL_FORGEJO_CLI" == "true" ]]; then
  info "Installing forgejo-cli..."
  FORGEJO_TAG=$(resolve_gh_release "Codeberg/forgejo-cli" 2>/dev/null || echo "")
  if [[ -n "$FORGEJO_TAG" ]]; then
    FORGEJO_VER="${FORGEJO_TAG#v}"
    FORGEJO_URL="https://codeberg.org/Codeberg/forgejo-cli/releases/download/${FORGEJO_TAG}/forgejo-cli_${FORGEJO_VER}_linux_${ARCH_GH}.tar.gz"
    TMP=$(mktemp /tmp/forgejo.XXXXXX.tar.gz)
    if curl -fsSL "$FORGEJO_URL" -o "$TMP" 2>/dev/null; then
      tar -xzf "$TMP" -C /usr/local/bin 2>/dev/null || true
      rm -f "$TMP"
    fi
  fi
  command -v forgejo-cli >/dev/null 2>&1 \
    && ok "forgejo-cli installed" \
    || warn "forgejo-cli install failed"
else
  skip "forgejo-cli (set install_forgejo_cli=true to enable)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Git platform CLIs installed:"
for cli in gh glab tea hub bb forgejo-cli; do
  if command -v "$cli" >/dev/null 2>&1; then
    ver=$("$cli" --version 2>/dev/null | head -1 || echo "installed")
    echo "    ✓ ${cli}: ${ver}"
  fi
done
echo ""
echo "    Authenticate with:"
echo "      gh auth login"
echo "      glab auth login"
echo "      tea login add"
