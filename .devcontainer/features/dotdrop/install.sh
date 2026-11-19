#!/usr/bin/env bash
# Installs dotdrop and optionally deploys a dotfiles profile.
# Runs inside the devcontainer build context as root.
#
# pip may not be on PATH yet when this feature runs (feature ordering is not
# guaranteed). We install python3-pip via apt as a fallback, then use pip3.
set -uo pipefail

VERSION="${VERSION:-latest}"
DOTFILES_REPO="${REPO:-}"
PROFILE="${PROFILE:-}"

# ── Ensure pip is available ───────────────────────────────────────────────────
PIP_BIN=""
for candidate in pip pip3 pip3.12 pip3.11 pip3.10; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PIP_BIN="$candidate"
    break
  fi
done

if [[ -z "$PIP_BIN" ]]; then
  echo "==> pip not found — installing python3-pip via apt..."
  apt-get update -qq 2>/dev/null || true
  apt-get install -y --no-install-recommends python3-pip 2>/dev/null || true
  for candidate in pip3 pip; do
    command -v "$candidate" >/dev/null 2>&1 && PIP_BIN="$candidate" && break
  done
fi

if [[ -z "$PIP_BIN" ]]; then
  echo "==> pip unavailable — dotdrop will not be installed." >&2
  echo "    Install manually: pip install dotdrop" >&2
  # Non-fatal: create config skeleton and exit cleanly
  PIP_BIN=""
fi

# ── Install dotdrop via pip ───────────────────────────────────────────────────
DOTDROP_BIN=""
if [[ -n "$PIP_BIN" ]]; then
  echo "==> Installing dotdrop (version: ${VERSION}) via ${PIP_BIN}..."
  if [[ "$VERSION" == "latest" ]]; then
    "$PIP_BIN" install --quiet --upgrade --break-system-packages dotdrop 2>/dev/null \
      || "$PIP_BIN" install --quiet --upgrade dotdrop 2>/dev/null \
      || true
  else
    "$PIP_BIN" install --quiet --break-system-packages "dotdrop==${VERSION}" 2>/dev/null \
      || "$PIP_BIN" install --quiet "dotdrop==${VERSION}" 2>/dev/null \
      || true
  fi

  for candidate in dotdrop /usr/local/bin/dotdrop /usr/bin/dotdrop ~/.local/bin/dotdrop; do
    command -v "$candidate" >/dev/null 2>&1 && DOTDROP_BIN="$candidate" && break
    [[ -x "$candidate" ]] && DOTDROP_BIN="$candidate" && break
  done

  if [[ -n "$DOTDROP_BIN" ]]; then
    echo "dotdrop $("$DOTDROP_BIN" --version 2>/dev/null || echo 'installed') at ${DOTDROP_BIN}"
  else
    echo "==> dotdrop binary not found after install — will skip deployment." >&2
  fi
fi

# ── Create fork-sync-all dotdrop config skeleton ─────────────────────────────
# This config manages the Incus/blincus template profiles used by
# docker-to-incus.sh. Each profile corresponds to a repo type.
DOTDROP_CONFIG_DIR="/workspaces/fork-sync-all/.dotdrop"
mkdir -p "${DOTDROP_CONFIG_DIR}/dotfiles"

if [[ ! -f "${DOTDROP_CONFIG_DIR}/config.yaml" ]]; then
  cat > "${DOTDROP_CONFIG_DIR}/config.yaml" << 'EOF'
# dotdrop configuration for fork-sync-all
# Manages Incus/blincus template profiles per repo type.
#
# Profiles correspond to application stacks detected by docker-to-incus.sh:
#   rust-service   — Rust/Cargo binary services (musl static linking)
#   go-service     — Go binary services
#   nextjs-app     — Next.js + Bun applications
#   vite-app       — Vite/TanStack applications (Bun runtime)
#   generic        — Fallback for unrecognised stacks
#
# Usage:
#   dotdrop install -c .dotdrop/config.yaml -p rust-service
#   dotdrop files   -c .dotdrop/config.yaml -p nextjs-app
#   dotdrop compare -c .dotdrop/config.yaml -p go-service

config:
  backup: true
  banner: false
  create: true
  dotpath: dotfiles
  ignoreempty: false
  keepdot: false
  longkey: false
  showdiff: false
  workdir: ~/.config/dotdrop

dotfiles:
  f_incus_image_rust:
    src: templates/rust-service/incus-image.yaml
    dst: "{{@@ dst_dir @@}}/incus-image.yaml"
  f_blincus_rust:
    src: templates/rust-service/blincus.yaml
    dst: "{{@@ dst_dir @@}}/blincus-{{@@ component @@}}.yaml"
  f_incus_image_go:
    src: templates/go-service/incus-image.yaml
    dst: "{{@@ dst_dir @@}}/incus-image.yaml"
  f_blincus_go:
    src: templates/go-service/blincus.yaml
    dst: "{{@@ dst_dir @@}}/blincus-{{@@ component @@}}.yaml"
  f_incus_image_nextjs:
    src: templates/nextjs-app/incus-image.yaml
    dst: "{{@@ dst_dir @@}}/incus-image.yaml"
  f_blincus_nextjs:
    src: templates/nextjs-app/blincus.yaml
    dst: "{{@@ dst_dir @@}}/blincus-{{@@ component @@}}.yaml"
  f_incus_image_vite:
    src: templates/vite-app/incus-image.yaml
    dst: "{{@@ dst_dir @@}}/incus-image.yaml"
  f_blincus_vite:
    src: templates/vite-app/blincus.yaml
    dst: "{{@@ dst_dir @@}}/blincus-{{@@ component @@}}.yaml"
  f_incus_image_generic:
    src: templates/generic/incus-image.yaml
    dst: "{{@@ dst_dir @@}}/incus-image.yaml"
  f_blincus_generic:
    src: templates/generic/blincus.yaml
    dst: "{{@@ dst_dir @@}}/blincus-{{@@ component @@}}.yaml"

variables:
  dst_dir: "/tmp/dotdrop-output"
  component: "app"

profiles:
  rust-service:
    dotfiles:
      - f_incus_image_rust
      - f_blincus_rust
  go-service:
    dotfiles:
      - f_incus_image_go
      - f_blincus_go
  nextjs-app:
    dotfiles:
      - f_incus_image_nextjs
      - f_blincus_nextjs
  vite-app:
    dotfiles:
      - f_incus_image_vite
      - f_blincus_vite
  generic:
    dotfiles:
      - f_incus_image_generic
      - f_blincus_generic
EOF
  echo "==> Created .dotdrop/config.yaml"
fi

# ── Create template stubs if they don't exist ─────────────────────────────────
for stack in rust-service go-service nextjs-app vite-app generic; do
  mkdir -p "${DOTDROP_CONFIG_DIR}/dotfiles/templates/${stack}"
  # Only create stubs — docker-to-incus.sh populates real content
  for tpl in incus-image.yaml blincus.yaml; do
    tpl_path="${DOTDROP_CONFIG_DIR}/dotfiles/templates/${stack}/${tpl}"
    if [[ ! -f "$tpl_path" ]]; then
      cat > "$tpl_path" << STUB
# dotdrop template: ${stack}/${tpl}
# Populated by scripts/docker-to-incus.sh
# Variables available: {{@@ component @@}}, {{@@ dst_dir @@}}
# See .dotdrop/config.yaml for profile definitions.
STUB
    fi
  done
done

# ── Optionally clone and deploy a personal dotfiles repo ──────────────────────
if [[ -n "$DOTFILES_REPO" && -n "$DOTDROP_BIN" ]]; then
  echo "==> Cloning dotfiles from ${DOTFILES_REPO}..."
  DOTFILES_DIR="${HOME}/dotfiles"
  if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    git clone --depth=1 "$DOTFILES_REPO" "$DOTFILES_DIR" 2>/dev/null \
      || { echo "==> Failed to clone dotfiles repo — skipping." >&2; }
  fi

  if [[ -d "$DOTFILES_DIR" ]]; then
    DEPLOY_PROFILE="${PROFILE:-$(hostname)}"
    echo "==> Deploying dotdrop profile '${DEPLOY_PROFILE}'..."
    cd "$DOTFILES_DIR"
    # Try dotdrop config in standard locations
    for cfg in config.yaml dotdrop/config.yaml .dotdrop/config.yaml; do
      if [[ -f "$cfg" ]]; then
        ${DOTDROP_BIN} install -c "$cfg" -p "$DEPLOY_PROFILE" --force 2>/dev/null \
          && echo "==> dotdrop profile '${DEPLOY_PROFILE}' deployed." \
          || echo "==> dotdrop deploy failed — check ${DOTFILES_DIR}/${cfg}" >&2
        break
      fi
    done
  fi
fi

echo ""
echo "==> dotdrop feature setup complete:"
[[ -n "$DOTDROP_BIN" ]] \
  && echo "    dotdrop — installed at ${DOTDROP_BIN}" \
  || echo "    dotdrop — NOT installed (install manually: pip install dotdrop)"
echo "    .dotdrop/ — fork-sync-all template profiles (rust/go/nextjs/vite/generic)"
echo ""
echo "    Usage:"
echo "      dotdrop install -c .dotdrop/config.yaml -p rust-service"
echo "      dotdrop files   -c .dotdrop/config.yaml -p nextjs-app"
