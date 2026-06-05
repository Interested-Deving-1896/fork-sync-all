#!/usr/bin/env bash
# Installs the Incus client and bidirectional import/export helpers.
# Runs inside the devcontainer build context as root.
#
# Network-dependent steps (zabbly apt repo, distrobuilder binary) are
# attempted but failures are non-fatal — the helper scripts (incus-import,
# incus-export) are always installed regardless.
set -uo pipefail

VERSION="${VERSION:-latest}"
REMOTE="${REMOTE:-}"
REMOTE_URL="${REMOTE_URL:-}"

# ── Install Incus client from zabbly stable repository ───────────────────────
# https://github.com/zabbly/incus — the canonical stable release channel
echo "==> Installing Incus client..."
apt-get update -qq 2>/dev/null || true
apt-get install -y --no-install-recommends curl ca-certificates gnupg 2>/dev/null || true

INCUS_INSTALLED=false
if command -v curl >/dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  if curl -fsSL --connect-timeout 10 https://pkgs.zabbly.com/key.asc \
      | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg 2>/dev/null; then
    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
    cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources << EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
EOF
    apt-get update -qq 2>/dev/null || true
    if apt-get install -y --no-install-recommends incus-client 2>/dev/null; then
      INCUS_INSTALLED=true
      echo "Incus client installed: $(incus version --client 2>/dev/null || echo 'ok')"
    fi
  fi
fi

if [[ "$INCUS_INSTALLED" != "true" ]]; then
  echo "==> Incus client not available in this build environment."
  echo "    Install manually after container start:"
  echo "    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor > /etc/apt/keyrings/zabbly.gpg"
  echo "    # then add zabbly apt source and: apt-get install incus-client"
fi

# ── Install distrobuilder (image builder) ─────────────────────────────────────
echo "==> Installing distrobuilder..."
DISTROBUILDER_INSTALLED=false
DISTROBUILDER_VERSION="3.1"
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

if command -v curl >/dev/null 2>&1; then
  if curl -fsSL --connect-timeout 15 \
      "https://github.com/lxc/distrobuilder/releases/download/v${DISTROBUILDER_VERSION}/distrobuilder-${DISTROBUILDER_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -C /usr/local/bin -xz distrobuilder 2>/dev/null; then
    chmod +x /usr/local/bin/distrobuilder
    DISTROBUILDER_INSTALLED=true
    echo "distrobuilder installed: $(distrobuilder --version 2>/dev/null || echo 'ok')"
  fi
fi

if [[ "$DISTROBUILDER_INSTALLED" != "true" ]]; then
  echo "==> distrobuilder not available in this build environment."
  echo "    Install manually: https://github.com/lxc/distrobuilder/releases"
fi

# ── Configure default remote if provided ─────────────────────────────────────
if [[ -n "$REMOTE" && -n "$REMOTE_URL" ]] && [[ "$INCUS_INSTALLED" == "true" ]]; then
  echo "==> Configuring Incus remote '${REMOTE}' → ${REMOTE_URL}..."
  incus remote add "$REMOTE" "$REMOTE_URL" --accept-certificate 2>/dev/null || true
  incus remote switch "$REMOTE" 2>/dev/null || true
fi

# ── Install bidirectional import/export helpers ───────────────────────────────
echo "==> Installing incus-import and incus-export helpers..."

cat > /usr/local/bin/incus-import << 'SCRIPT'
#!/usr/bin/env bash
# incus-import — push a local distrobuilder output or OCI tarball into Incus.
#
# Usage:
#   incus-import <path/to/incus.tar.xz> [--alias <name>] [--remote <remote>]
#   incus-import <path/to/incus-image.yaml> [--alias <name>] [--remote <remote>]
#
# If given a .yaml file, runs distrobuilder first then imports the result.
# If given a .tar.xz / .tar.gz, imports directly via `incus image import`.
#
# Options:
#   --alias   <name>    Image alias to assign (default: basename of input)
#   --remote  <name>    Incus remote to import into (default: current remote)
#   --build-dir <dir>   Directory for distrobuilder output (default: /tmp/incus-build-XXXX)
#   --vm                Build/import as VM image instead of container
set -uo pipefail

INPUT=""
ALIAS=""
REMOTE=""
BUILD_DIR=""
VM_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)     ALIAS="$2";     shift 2 ;;
    --remote)    REMOTE="$2";    shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --vm)        VM_FLAG="--vm"; shift ;;
    -*)          echo "Unknown option: $1" >&2; exit 1 ;;
    *)           INPUT="$1"; shift ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Usage: incus-import <file.tar.xz|incus-image.yaml> [--alias name] [--remote name]" >&2
  exit 1
fi

REMOTE_PREFIX="${REMOTE:+${REMOTE}:}"

# ── Build from distrobuilder YAML ─────────────────────────────────────────────
if [[ "$INPUT" == *.yaml || "$INPUT" == *.yml ]]; then
  echo "[incus-import] Building image from ${INPUT}..."
  BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/incus-build-XXXX)}"
  CLEANUP_BUILD=true
  distrobuilder build-incus "$INPUT" "$BUILD_DIR" ${VM_FLAG}
  # distrobuilder outputs incus.tar.xz (container) or incus.tar.xz + incus.qcow2 (VM)
  TARBALL="${BUILD_DIR}/incus.tar.xz"
  if [[ ! -f "$TARBALL" ]]; then
    echo "[incus-import] ERROR: distrobuilder did not produce ${TARBALL}" >&2
    exit 1
  fi
  INPUT="$TARBALL"
else
  CLEANUP_BUILD=false
fi

# ── Derive alias ──────────────────────────────────────────────────────────────
if [[ -z "$ALIAS" ]]; then
  ALIAS=$(basename "$INPUT" .tar.xz)
  ALIAS=$(basename "$ALIAS" .tar.gz)
fi

# ── Import into Incus ─────────────────────────────────────────────────────────
echo "[incus-import] Importing ${INPUT} as '${ALIAS}' into ${REMOTE_PREFIX:-local}..."
incus image import "$INPUT" ${REMOTE_PREFIX:+--remote "$REMOTE"} --alias "$ALIAS"
echo "[incus-import] Done. Image alias: ${REMOTE_PREFIX}${ALIAS}"
echo "[incus-import] Launch with: incus launch ${REMOTE_PREFIX}${ALIAS} <instance-name>"

# ── Cleanup temp build dir ────────────────────────────────────────────────────
if [[ "$CLEANUP_BUILD" == "true" && -n "${BUILD_DIR:-}" ]]; then
  rm -rf "$BUILD_DIR"
fi
SCRIPT

cat > /usr/local/bin/incus-export << 'SCRIPT'
#!/usr/bin/env bash
# incus-export — pull an Incus image or running instance out as a tarball.
#
# Usage:
#   incus-export <image-alias>   [--output <file>] [--remote <remote>] [--format oci|incus]
#   incus-export --instance <name> [--output <file>] [--remote <remote>]
#
# Modes:
#   image alias   — exports an existing Incus image to a local tarball
#   --instance    — stops the instance, publishes it as an image, exports it,
#                   then restarts the instance (non-destructive)
#
# Options:
#   --output  <file>    Output path (default: <alias>.tar.gz in current dir)
#   --remote  <name>    Incus remote to export from (default: current remote)
#   --format  oci|incus Export format: 'oci' for OCI-compatible tarball,
#                       'incus' for native Incus image tarball (default: incus)
#   --instance <name>   Export a running/stopped instance instead of an image
set -uo pipefail

SOURCE=""
INSTANCE=""
OUTPUT=""
REMOTE=""
FORMAT="incus"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)   OUTPUT="$2";   shift 2 ;;
    --remote)   REMOTE="$2";   shift 2 ;;
    --format)   FORMAT="$2";   shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          SOURCE="$1"; shift ;;
  esac
done

REMOTE_PREFIX="${REMOTE:+${REMOTE}:}"
REMOTE_ARG="${REMOTE:+--remote $REMOTE}"

# ── Instance → image → export ─────────────────────────────────────────────────
if [[ -n "$INSTANCE" ]]; then
  SOURCE="$INSTANCE"
  TMP_ALIAS="export-$(date +%s)-${INSTANCE}"
  echo "[incus-export] Publishing instance '${INSTANCE}' as temporary image '${TMP_ALIAS}'..."

  WAS_RUNNING=false
  if incus info ${REMOTE_ARG} "$INSTANCE" 2>/dev/null | grep -q "Status: RUNNING"; then
    WAS_RUNNING=true
    incus stop ${REMOTE_ARG} "$INSTANCE"
  fi

  incus publish ${REMOTE_ARG} "$INSTANCE" --alias "$TMP_ALIAS"

  if [[ "$WAS_RUNNING" == "true" ]]; then
    incus start ${REMOTE_ARG} "$INSTANCE"
  fi

  SOURCE="$TMP_ALIAS"
  CLEANUP_IMAGE=true
else
  CLEANUP_IMAGE=false
fi

# ── Derive output path ────────────────────────────────────────────────────────
if [[ -z "$OUTPUT" ]]; then
  SAFE=$(echo "$SOURCE" | tr '/:' '--')
  OUTPUT="${SAFE}.tar.gz"
fi

# ── Export ────────────────────────────────────────────────────────────────────
echo "[incus-export] Exporting '${REMOTE_PREFIX}${SOURCE}' → ${OUTPUT} (format: ${FORMAT})..."

case "$FORMAT" in
  oci)
    # Export as OCI tarball — compatible with docker load / skopeo
    incus image export ${REMOTE_ARG} "$SOURCE" "${OUTPUT%.tar.gz}" --format oci
    ;;
  incus|*)
    incus image export ${REMOTE_ARG} "$SOURCE" "${OUTPUT%.tar.gz}"
    ;;
esac

echo "[incus-export] Done: ${OUTPUT}"
echo "[incus-export] Import back with: incus-import ${OUTPUT} --alias ${SOURCE}"

# ── Cleanup temp image ────────────────────────────────────────────────────────
if [[ "$CLEANUP_IMAGE" == "true" ]]; then
  incus image delete ${REMOTE_ARG} "$SOURCE" 2>/dev/null || true
fi
SCRIPT

chmod +x /usr/local/bin/incus-import /usr/local/bin/incus-export

# ── Shell completions ─────────────────────────────────────────────────────────
if command -v incus >/dev/null 2>&1 && [ -d /etc/bash_completion.d ]; then
  incus completion bash > /etc/bash_completion.d/incus 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Incus feature setup complete:"
echo "    incus-import   — push local image/yaml into Incus remote (always available)"
echo "    incus-export   — pull Incus image/instance to local tarball (always available)"
[[ "$INCUS_INSTALLED"        == "true" ]] && echo "    incus          — Incus CLI client (installed)" \
                                          || echo "    incus          — NOT installed (install manually post-start)"
[[ "$DISTROBUILDER_INSTALLED" == "true" ]] && echo "    distrobuilder  — image builder (installed)" \
                                           || echo "    distrobuilder  — NOT installed (install manually post-start)"
echo ""
echo "    Bidirectional workflow:"
echo "      Build:  distrobuilder build-incus incus-image.yaml ./out"
echo "      Import: incus-import ./out/incus.tar.xz --alias myapp"
echo "      Export: incus-export myapp --output myapp.tar.gz"
echo "      OCI:    incus-export myapp --format oci --output myapp-oci.tar.gz"
echo ""
if [[ -n "$REMOTE" ]]; then
  echo "    Default remote: ${REMOTE} (${REMOTE_URL})"
fi
