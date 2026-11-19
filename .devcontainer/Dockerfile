FROM mcr.microsoft.com/devcontainers/base:2.0.4-noble

# Install build dependencies for btrfs-dwarfs-framework userspace tools
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
        build-essential \
        cmake \
        pkg-config \
        git \
        curl \
        wget \
        python3 \
        python3-pip \
        python3-venv \
        btrfs-progs \
        fuse3 \
        fuse-overlayfs \
        libfuse3-dev \
        jq \
        golang-go \
        git-filter-repo \
    && rm -rf /var/lib/apt/lists/*

# Install Kubo (IPFS) daemon
# Kubo exposes the HTTP RPC API at http://127.0.0.1:5001 used by bdfs-pin-helper
ARG KUBO_VERSION=v0.28.0
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
        amd64) KUBO_ARCH="amd64" ;; \
        arm64) KUBO_ARCH="arm64" ;; \
        *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac \
    && curl -sSfL "https://dist.ipfs.tech/kubo/${KUBO_VERSION}/kubo_${KUBO_VERSION}_linux-${KUBO_ARCH}.tar.gz" \
        -o /tmp/kubo.tar.gz \
    && tar -xzf /tmp/kubo.tar.gz -C /tmp \
    && /tmp/kubo/install.sh \
    && rm -rf /tmp/kubo /tmp/kubo.tar.gz \
    && ipfs --version
