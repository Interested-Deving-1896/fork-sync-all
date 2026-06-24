#!/usr/bin/env bash
# Installs the Incus daemon + client (or client-only on restricted runners).
# Runs inside the devcontainer build context as root.
#
# Capability requirements for the full daemon:
#   CAP_SYS_ADMIN  — namespace creation, mount operations
#   CAP_NET_ADMIN  — bridge/veth creation, nftables rules
#   /dev/kvm       — optional, for hardware-accelerated VMs
#   /dev/fuse      — optional, for fuse-overlayfs rootfs driver
#
# On runners that lack CAP_SYS_ADMIN/CAP_NET_ADMIN the daemon is still
# installed but will not start. The client (incus CLI) and all helpers
# are always installed so remote Incus servers can be managed.
#
# QEMU is installed when install_qemu=true (default). Incus uses /dev/kvm
# when present; falls back to QEMU TCG (software emulation) otherwise.
# TCG is slow but functional for testing and image building.
set -uo pipefail

VERSION="${VERSION:-latest}"
INSTALL_QEMU="${INSTALL_QEMU:-true}"
REMOTE="${REMOTE:-}"
REMOTE_URL="${REMOTE_URL:-}"

info()  { echo "[incus-feature] $*" >&2; }
warn()  { echo "[incus-feature][warn] $*" >&2; }

# ── Capability detection ───────────────────────────────────────────────────────
# CAP_SYS_ADMIN=21, CAP_NET_ADMIN=12
_cap_eff=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null || echo "0")
_cap_dec=$(python3 -c "print(int('${_cap_eff}', 16))" 2>/dev/null || echo "0")
_has_sys_admin=$(python3 -c "print('yes' if (${_cap_dec} >> 21) & 1 else 'no')" 2>/dev/null || echo "no")
_has_net_admin=$(python3 -c "print('yes' if (${_cap_dec} >> 12) & 1 else 'no')" 2>/dev/null || echo "no")

if [[ "$_has_sys_admin" == "yes" && "$_has_net_admin" == "yes" ]]; then
    DAEMON_MODE="full"
    info "CAP_SYS_ADMIN + CAP_NET_ADMIN present — installing full daemon"
else
    DAEMON_MODE="client-only"
    warn "CAP_SYS_ADMIN or CAP_NET_ADMIN missing (CapEff=0x${_cap_eff})"
    warn "Installing client only — daemon will not start on this runner"
    warn "To enable the daemon: use a privileged runner or add capabilities"
fi

# Explicit override
[[ "${VERSION}" == "client-only" ]] && DAEMON_MODE="client-only"

# ── APT setup ─────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gpg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.zabbly.com/key.asc" \
    | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg

_codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-resolute}}")

if [[ "$DAEMON_MODE" == "full" ]]; then
    cat > /etc/apt/sources.list.d/zabbly-incus-daily.sources << SRCEOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/daily
Suites: ${_codename}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/zabbly.gpg
SRCEOF
    apt-get update -qq
    apt-get install -y -qq incus incus-extra
    info "Installed incus daemon (daily channel)"
else
    cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources << SRCEOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${_codename}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/zabbly.gpg
SRCEOF
    apt-get update -qq
    apt-get install -y -qq incus-client
    info "Installed incus-client only (stable channel)"
fi

# ── QEMU ──────────────────────────────────────────────────────────────────────
if [[ "${INSTALL_QEMU}" == "true" ]]; then
    info "Installing QEMU for VM support..."
    apt-get install -y -qq \
        qemu-system-x86 \
        qemu-utils \
        qemu-efi-amd64 \
        ovmf \
        2>/dev/null || warn "QEMU install failed — VM support unavailable"

    if [[ -e /dev/kvm ]]; then
        info "KVM device present — hardware-accelerated VMs available"
    else
        warn "/dev/kvm not present — VMs will use QEMU TCG (software emulation)"
        warn "To enable KVM: runner must expose /dev/kvm (nested virt required)"
    fi
fi

# ── Daemon runtime deps ────────────────────────────────────────────────────────
if [[ "$DAEMON_MODE" == "full" ]]; then
    apt-get install -y -qq \
        attr dnsmasq-base fuse3 gnutls-bin nftables \
        iputils-ping iw kmod lshw gdisk squashfs-tools xdelta3 \
        2>/dev/null || warn "Some runtime deps failed to install"

    # Enable unprivileged user namespaces if the sysctl exists
    if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
        echo 1 > /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true
    fi

    # Add vscode user to incus-admin group
    if getent group incus-admin &>/dev/null; then
        usermod -aG incus-admin vscode 2>/dev/null || true
        info "Added vscode to incus-admin group"
    fi
fi

# ── Remote bootstrap ───────────────────────────────────────────────────────────
if [[ -n "${REMOTE}" && -n "${REMOTE_URL}" ]]; then
    cat > /usr/local/bin/incus-add-remote.sh << REMEOF
#!/usr/bin/env bash
set -euo pipefail
if ! incus remote list | grep -q "^| ${REMOTE} "; then
    incus remote add "${REMOTE}" "${REMOTE_URL}" --accept-certificate 2>/dev/null || true
    incus remote switch "${REMOTE}" 2>/dev/null || true
fi
REMEOF
    chmod +x /usr/local/bin/incus-add-remote.sh
    echo '[[ -x /usr/local/bin/incus-add-remote.sh ]] && /usr/local/bin/incus-add-remote.sh' \
        >> /home/vscode/.bashrc 2>/dev/null || true
    info "Remote bootstrap installed for ${REMOTE} -> ${REMOTE_URL}"
fi

# ── Shell completions ──────────────────────────────────────────────────────────
command -v incus &>/dev/null && \
    incus completion bash > /etc/bash_completion.d/incus 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
info "Installation complete"
info "  Mode:  ${DAEMON_MODE}"
info "  QEMU:  ${INSTALL_QEMU}"
info "  KVM:   $([ -e /dev/kvm ] && echo 'available' || echo 'not available (TCG fallback)')"
info "  incus: $(incus version --client 2>/dev/null || echo 'unknown')"
if [[ "$DAEMON_MODE" == "full" ]]; then
    info "  incusd is installed but not started here."
    info "  It is started by the 'incusd' automation service at container start."
fi
