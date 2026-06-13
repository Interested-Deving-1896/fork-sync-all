#!/usr/bin/env bash
# scripts/docker-to-incus.sh
#
# For every Interested-Deving-1896 repo that contains Docker artifacts
# (Dockerfile, docker-compose.yml, .dockerignore), generate Incus equivalents
# and commit them back via the GitHub Contents API.
#
# Conversions performed:
#   Dockerfile            → incus-image.yaml  (distrobuilder definition)
#   docker-compose.yml    → incus-compose.yaml (digizyne/incus-compose format)
#                         + per-service incus.yaml (standalone instance config)
#   .dockerignore         → removed (Incus uses distrobuilder source filters)
#
# The originals are deleted in the same commit so the repo is Docker-free.
#
# Idempotent: repos that already have incus-image.yaml or incus-compose.yaml
# at the root are skipped unless FORCE=true.
#
# Requires:
#   GH_TOKEN        — PAT with repo + workflow scopes on UPSTREAM_OWNER
#   UPSTREAM_OWNER  — org to scan (default: Interested-Deving-1896)
#
# Optional:
#   REPO_FILTER     — substring; only process repos whose name contains this
#   DRY_RUN         — "true" to print changes without writing
#   FORCE           — "true" to re-generate even if Incus files already exist
#   BUDGET_MINUTES  — runtime cap (default: 55)
#   COMMIT_AUTHOR_NAME  — git author name for commits
#   COMMIT_AUTHOR_EMAIL — git author email for commits

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

UPSTREAM_OWNER="${UPSTREAM_OWNER:-Interested-Deving-1896}"
REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
COMMIT_AUTHOR_NAME="${COMMIT_AUTHOR_NAME:-fork-sync-all[bot]}"
COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR_EMAIL:-fork-sync-all@users.noreply.github.com}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/includes/budget.sh"
budget_init

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

[[ "$DRY_RUN" == "true" ]] && echo "[docker-to-incus] Dry run — no commits will be made."
[[ "$FORCE"   == "true" ]] && echo "[docker-to-incus] Force mode — re-generating existing Incus files."
[[ -n "$REPO_FILTER"    ]] && echo "[docker-to-incus] Repo filter: '${REPO_FILTER}'"

converted=0
skipped=0
failed=0

info()  { echo "[docker-to-incus] $*" >&2; }
warn()  { echo "[docker-to-incus][warn] $*" >&2; }

# ── API helpers ───────────────────────────────────────────────────────────────

api_get() { curl -sf "${AUTH[@]}" "$@"; }

# Fetch file content (base64) from GitHub Contents API
get_file_content() {
  local repo="$1" path="$2"
  api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}/contents/${path}" 2>/dev/null \
    | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode('utf-8','replace'))" 2>/dev/null || true
}

# Get file SHA (needed for update/delete via Contents API)
get_file_sha() {
  local repo="$1" path="$2"
  api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}/contents/${path}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || true
}

# Put a file via Contents API (create or update)
put_file() {
  local repo="$1" path="$2" message="$3" content_b64="$4" sha="${5:-}"
  local payload
  payload=$(python3 -c "
import json, sys
d = {
    'message': sys.argv[1],
    'content': sys.argv[2],
    'author': {'name': sys.argv[3], 'email': sys.argv[4]},
}
if sys.argv[5]:
    d['sha'] = sys.argv[5]
print(json.dumps(d))
" "$message" "$content_b64" "$COMMIT_AUTHOR_NAME" "$COMMIT_AUTHOR_EMAIL" "$sha")

  curl -sf -X PUT "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${API}/repos/${UPSTREAM_OWNER}/${repo}/contents/${path}" >/dev/null
}

# Delete a file via Contents API
delete_file() {
  local repo="$1" path="$2" message="$3" sha="$4"
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'message': sys.argv[1],
    'sha': sys.argv[2],
    'author': {'name': sys.argv[3], 'email': sys.argv[4]},
}))
" "$message" "$sha" "$COMMIT_AUTHOR_NAME" "$COMMIT_AUTHOR_EMAIL")

  curl -sf -X DELETE "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${API}/repos/${UPSTREAM_OWNER}/${repo}/contents/${path}" >/dev/null
}

b64_encode() { python3 -c "import sys,base64; print(base64.b64encode(sys.stdin.buffer.read()).decode())" < /dev/stdin; }

# ── dotdrop template resolution ───────────────────────────────────────────────
# If dotdrop is available and .dotdrop/config.yaml exists, use managed templates
# instead of the inline Python generators. Falls back to inline generators when
# dotdrop is not installed (e.g. in GitHub Actions without the devcontainer).
DOTDROP_CONFIG="${_SCRIPT_DIR}/../.dotdrop/config.yaml"
DOTDROP_BIN=$(command -v dotdrop 2>/dev/null || true)

# Detect stack type from Dockerfile content
detect_stack() {
  local content="$1"
  if echo "$content" | grep -qi "^FROM.*rust\|cargo build\|rustup"; then
    echo "rust-service"
  elif echo "$content" | grep -qi "^FROM.*golang\|^FROM.*go:\|go build\|go mod"; then
    echo "go-service"
  elif echo "$content" | grep -qi "bun run start\|next build\|next start\|nextjs"; then
    echo "nextjs-app"
  elif echo "$content" | grep -qi "bun\|vite build\|vite"; then
    echo "vite-app"
  else
    echo "generic"
  fi
}

# Render a dotdrop template for a given profile and component, writing to stdout.
# Falls back to the inline Python generator if dotdrop is unavailable.
render_dotdrop_template() {
  local profile="$1" component="$2" template_file="$3"
  local tpl_path="${_SCRIPT_DIR}/../.dotdrop/dotfiles/templates/${profile}/${template_file}"

  if [[ -n "$DOTDROP_BIN" && -f "$DOTDROP_CONFIG" && -f "$tpl_path" ]]; then
    # Use dotdrop's template engine to render with variable substitution
    "$DOTDROP_BIN" template \
      -c "$DOTDROP_CONFIG" \
      -V "component=${component}" \
      -V "dst_dir=/tmp/dotdrop-render-$$" \
      "$tpl_path" 2>/dev/null || cat "$tpl_path"
  else
    # Return raw template with manual substitution as fallback
    sed "s/{{@@ component @@}}/${component}/g" "$tpl_path" 2>/dev/null || true
  fi
}

# ── Repo list via GraphQL ─────────────────────────────────────────────────────

info "Fetching repo list for ${UPSTREAM_OWNER}..."

REPOS=$(python3 - <<PYEOF
import urllib.request, json, os, sys

token = os.environ["GH_TOKEN"]
owner = os.environ.get("UPSTREAM_OWNER", "Interested-Deving-1896")
filter_str = os.environ.get("REPO_FILTER", "")

query = """
query(\$owner: String!, \$after: String) {
  organization(login: \$owner) {
    repositories(first: 100, after: \$after, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes { name isArchived }
    }
  }
}
"""

repos = []
cursor = None
while True:
    variables = {"owner": owner}
    if cursor:
        variables["after"] = cursor
    payload = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        "https://api.github.com/graphql",
        data=payload,
        headers={"Authorization": f"token {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        data = json.load(r)
    nodes = data["data"]["organization"]["repositories"]["nodes"]
    page_info = data["data"]["organization"]["repositories"]["pageInfo"]
    for n in nodes:
        if n["isArchived"]:
            continue
        if filter_str and filter_str not in n["name"]:
            continue
        repos.append(n["name"])
    if not page_info["hasNextPage"]:
        break
    cursor = page_info["endCursor"]

print("\n".join(repos))
PYEOF
)

if [[ -z "$REPOS" ]]; then
  info "No repos found — exiting."
  exit 0
fi

repo_count=$(echo "$REPOS" | wc -l | tr -d ' ')
info "Found ${repo_count} repos to scan."

# ── Generators ───────────────────────────────────────────────────────────────

# generate_incus_image REPO COMPONENT DOCKERFILE_CONTENT DOCKERFILE_PATH
# Emits a distrobuilder YAML definition derived from the Dockerfile.
# Uses dotdrop-managed templates when available; falls back to inline Python.
generate_incus_image() {
  local repo="$1" component="$2" dockerfile="$3" dockerfile_path="$4"
  local stack
  stack=$(detect_stack "$dockerfile")
  local rendered
  rendered=$(render_dotdrop_template "$stack" "$component" "incus-image.yaml")
  if [[ -n "$rendered" && "$rendered" != *"{{@@"* ]]; then
    echo "$rendered"
    return
  fi
  # Fall through to inline Python generator
  python3 - "$repo" "$component" "$dockerfile_path" <<'PYEOF'
import sys, re, textwrap

repo      = sys.argv[1]
component = sys.argv[2]
src_path  = sys.argv[3]
content   = sys.stdin.read()

lines = content.splitlines()

# ── Parse Dockerfile ──────────────────────────────────────────────────────────
base_image   = "ubuntu/24.04"
packages     = []
run_commands = []
expose_ports = []
env_vars     = {}
workdir      = "/opt/app"
entrypoint   = ""
cmd          = ""

for line in lines:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    upper = line.upper()

    if upper.startswith("FROM "):
        img = line.split()[1].lower()
        # Map common base images to Incus image names
        if "ubuntu" in img:
            ver = re.search(r"(\d+\.\d+|\d+)", img)
            base_image = f"ubuntu/{ver.group(1)}/cloud" if ver else "ubuntu/24.04/cloud"
        elif "debian" in img:
            ver = re.search(r"(\d+|bookworm|bullseye|buster|trixie)", img)
            base_image = f"debian/{ver.group(1)}/cloud" if ver else "debian/12/cloud"
        elif "alpine" in img:
            base_image = "alpine/3.21"
        elif "rust" in img:
            base_image = "ubuntu/24.04/cloud"
            packages += ["curl", "build-essential", "pkg-config", "libssl-dev", "musl-tools"]
            run_commands.append("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable")
            run_commands.append("echo 'source /root/.cargo/env' >> /root/.bashrc")
        elif "golang" in img or "go:" in img:
            ver = re.search(r"(\d+\.\d+)", img)
            go_ver = ver.group(1) if ver else "1.23"
            base_image = "ubuntu/24.04/cloud"
            packages += ["curl", "ca-certificates"]
            run_commands.append(f"curl -fsSL https://go.dev/dl/go{go_ver}.linux-amd64.tar.gz | tar -C /usr/local -xz")
            run_commands.append("echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc")
        elif "node" in img or "bun" in img:
            base_image = "ubuntu/24.04/cloud"
            packages += ["curl", "ca-certificates", "unzip"]
            if "bun" in img:
                run_commands.append("curl -fsSL https://bun.sh/install | bash")
            else:
                ver = re.search(r"(\d+)", img)
                node_ver = ver.group(1) if ver else "22"
                run_commands.append(f"curl -fsSL https://deb.nodesource.com/setup_{node_ver}.x | bash -")
                packages.append("nodejs")
        # scratch → minimal ubuntu
        elif "scratch" in img:
            base_image = "ubuntu/24.04/cloud"

    elif upper.startswith("RUN "):
        cmd_part = line[4:].strip()
        # Collapse line continuations
        cmd_part = re.sub(r"\s*\\\s*\n\s*", " ", cmd_part)
        # Extract apt-get installs
        apt_match = re.findall(r"apt(?:-get)?\s+install\s+(?:-y\s+)?([^\|&;]+)", cmd_part)
        for m in apt_match:
            pkgs = [p.strip() for p in m.split() if p.strip() and not p.startswith("-")]
            packages.extend(pkgs)
        # Keep non-apt commands as runcmd entries
        if not re.search(r"apt(?:-get)?\s+(install|update|upgrade|clean|autoremove)", cmd_part):
            run_commands.append(cmd_part)

    elif upper.startswith("EXPOSE "):
        expose_ports.append(line.split()[1])

    elif upper.startswith("ENV "):
        parts = line[4:].strip().split("=", 1)
        if len(parts) == 2:
            env_vars[parts[0].strip()] = parts[1].strip()

    elif upper.startswith("WORKDIR "):
        workdir = line.split()[1]

    elif upper.startswith("ENTRYPOINT ") or upper.startswith("CMD "):
        val = line.split(None, 1)[1].strip().strip("[]").replace('"', "")
        if upper.startswith("ENTRYPOINT"):
            entrypoint = val
        else:
            cmd = val

service_cmd = entrypoint or cmd or f"/opt/{component}/app"

# Deduplicate packages preserving order
seen = set()
unique_pkgs = []
for p in packages:
    if p not in seen and p not in ("update", "upgrade", "-y", "&&"):
        seen.add(p)
        unique_pkgs.append(p)

pkg_list = "\n".join(f"        - {p}" for p in unique_pkgs) if unique_pkgs else "        - ca-certificates"
run_list = "\n".join(f"      - {c}" for c in run_commands) if run_commands else "      # No additional setup commands"

env_block = ""
if env_vars:
    env_block = "\n".join(f"      {k}={v}" for k, v in env_vars.items())

port_comment = f"# Exposes: {', '.join(expose_ports)}" if expose_ports else ""
proxy_port = expose_ports[0] if expose_ports else "8080"

print(f"""\
# distrobuilder image definition for {component}.
# Generated by docker-to-incus.sh from {src_path}.
# Review and adjust before running distrobuilder.
#
# Build:
#   distrobuilder build-incus incus-image.yaml ./build-output
#   incus image import build-output/incus.tar.xz --alias {component}
# {port_comment}

image:
  name: {component}
  distribution: ubuntu
  release: noble
  description: {repo}/{component} service
  architecture: x86_64

source:
  downloader: debootstrap
  url: http://archive.ubuntu.com/ubuntu
  suite: noble
  same_as: noble
  keyserver: keyserver.ubuntu.com
  keys:
    - 0x871920D1991BC93C

targets:
  incus:
    vm: false

packages:
  manager: apt
  update: true
  cleanup: true
  sets:
    - packages:
{pkg_list}
      action: install

actions:
  - trigger: post-packages
    action: |-
      #!/bin/sh
      set -eux
{run_list}

      mkdir -p {workdir}

  - trigger: post-files
    action: |-
      #!/bin/sh
      set -eux

      cat > /etc/systemd/system/{component}.service << 'EOF'
      [Unit]
      Description={component}
      After=network.target

      [Service]
      Type=simple
      User=root
      WorkingDirectory={workdir}
      EnvironmentFile=-/etc/{component}.env
      ExecStart={service_cmd}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
      EOF

      systemctl enable {component}

files:
  - path: /etc/hostname
    generator: hostname
  - path: /etc/hosts
    generator: hosts
  - path: /etc/machine-id
    generator: dump
""")
PYEOF
}

# generate_blincus_template REPO COMPONENT DOCKERFILE_CONTENT DOCKERFILE_PATH
# Emits a blincus cloud-init template (YAML) compatible with:
#   blincus launch -t <component> <instance-name>
# Template is installed to ~/.config/blincus/cloud-init/<component>.yaml
# Uses dotdrop-managed templates when available; falls back to inline Python.
generate_blincus_template() {
  local repo="$1" component="$2" dockerfile="$3" dockerfile_path="$4"
  local stack
  stack=$(detect_stack "$dockerfile")
  local rendered
  rendered=$(render_dotdrop_template "$stack" "$component" "blincus.yaml")
  if [[ -n "$rendered" && "$rendered" != *"{{@@"* ]]; then
    echo "$rendered"
    return
  fi
  # Fall through to inline Python generator
  local dockerfile_path="$4"
  python3 - "$repo" "$component" "$dockerfile_path" <<'PYEOF'
import sys, re

repo      = sys.argv[1]
component = sys.argv[2]
src_path  = sys.argv[3]
content   = sys.stdin.read()

lines = content.splitlines()

# Parse base image to pick arch and package manager
base_image  = "ubuntu"
pkg_manager = "apt"
packages    = ["curl", "wget", "openssh-server", "git"]
run_cmds    = []
expose_ports = []
workdir     = "/opt/app"
service_cmd = ""

for line in lines:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    upper = line.upper()

    if upper.startswith("FROM "):
        img = line.split()[1].lower()
        if "alpine" in img:
            base_image  = "alpine"
            pkg_manager = "apk"
        elif "fedora" in img or "centos" in img or "rhel" in img:
            base_image  = "fedora"
            pkg_manager = "dnf"
        elif "arch" in img:
            base_image  = "archlinux"
            pkg_manager = "pacman"
        elif "debian" in img:
            base_image  = "debian"
            pkg_manager = "apt"
        else:
            base_image  = "ubuntu"
            pkg_manager = "apt"

    elif upper.startswith("RUN "):
        cmd_part = line[4:].strip()
        cmd_part = re.sub(r"\s*\\\s*\n\s*", " ", cmd_part)
        # Extract apt/dnf/apk installs into packages list
        apt_match = re.findall(
            r"(?:apt(?:-get)?|dnf|apk|pacman)\s+(?:install|add)\s+(?:-[^\s]+\s+)*([^\|&;]+)",
            cmd_part
        )
        for m in apt_match:
            pkgs = [p.strip() for p in m.split()
                    if p.strip() and not p.startswith("-")]
            packages.extend(pkgs)
        # Non-package-manager commands become runcmd entries
        if not re.search(
            r"(?:apt(?:-get)?|dnf|apk|pacman)\s+(?:install|add|update|upgrade|clean)",
            cmd_part
        ):
            run_cmds.append(cmd_part)

    elif upper.startswith("EXPOSE "):
        expose_ports.append(line.split()[1])

    elif upper.startswith("WORKDIR "):
        workdir = line.split()[1]

    elif upper.startswith("ENTRYPOINT ") or upper.startswith("CMD "):
        val = line.split(None, 1)[1].strip().strip("[]").replace('"', "")
        service_cmd = val

# Deduplicate packages
seen = set()
unique_pkgs = []
for p in packages:
    if p not in seen and p not in ("update", "upgrade", "-y", "&&", "install"):
        seen.add(p)
        unique_pkgs.append(p)

pkg_list = "\n".join(f"  - {p}" for p in unique_pkgs)

# Build runcmd block — always include the service start as last entry
runcmd_entries = []
for c in run_cmds:
    runcmd_entries.append(f'  - [ sh, -c, "{c}" ]')
# Standard blincus hook — runs /opt/scripts/init.sh if present
runcmd_entries.append('  - [ sh, -c, "[ -x /opt/scripts/init.sh ] && /opt/scripts/init.sh" ]')
if service_cmd:
    runcmd_entries.append(f'  - [ sh, -c, "systemctl enable --now {component} 2>/dev/null || true" ]')

runcmd_block = "\n".join(runcmd_entries)

port_note = f"# Exposes port(s): {', '.join(expose_ports)}" if expose_ports else ""

# sudo group varies by distro
sudo_groups = {
    "ubuntu": "[adm, cdrom, dip, sudo]",
    "debian": "[adm, cdrom, dip, sudo]",
    "fedora": "[adm, wheel]",
    "archlinux": "[wheel]",
    "alpine": "[wheel]",
}.get(base_image, "[sudo]")

print(f"""\
# blincus cloud-init template for {component}
# Generated by docker-to-incus.sh from {src_path}
#
# Install:
#   cp {component}.yaml ~/.config/blincus/cloud-init/
#
# Launch:
#   blincus launch -t {component} my-{component}
#
# Or as a VM (t3-style sizing):
#   blincus launch --vm medium -t {component} my-{component}
# {port_note}

architecture: x86_64
config:
  user.user-data: |-
    #cloud-config
    packages:
{pkg_list}
    users:
      - name: BLINCUSUSER
        plain_text_passwd: 'BLINCUSPASSWORD'
        home: /home/BLINCUSUSER
        shell: /bin/bash
        lock_passwd: True
        gecos: BLINCUSFULLNAME
        groups: {sudo_groups}
        sudo: ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - SSHKEY
    runcmd:
{runcmd_block}
description: "{repo}/{component} — generated blincus template"
""")
PYEOF
}

# generate_incus_compose REPO COMPOSE_CONTENT COMPOSE_PATH
# Emits an incus-compose.yaml (digizyne/incus-compose format) from docker-compose.
generate_incus_compose() {
  local repo="$1" compose_path="$3"
  python3 - "$repo" "$compose_path" <<'PYEOF'
import sys, re

repo      = sys.argv[1]
src_path  = sys.argv[2]
content   = sys.stdin.read()

# ── Minimal docker-compose parser ─────────────────────────────────────────────
# We only need: services, their image/ports/environment/volumes
# Use regex rather than yaml to avoid requiring PyYAML on the runner.

services = {}
current_service = None
current_section = None

for line in content.splitlines():
    # Top-level sections
    if re.match(r'^services\s*:', line):
        current_section = "services"
        continue
    if re.match(r'^volumes\s*:', line):
        current_section = "volumes"
        continue
    if re.match(r'^networks\s*:', line):
        current_section = "networks"
        continue

    if current_section == "services":
        # Service name (2-space indent, key:)
        m = re.match(r'^  ([a-zA-Z0-9_-]+)\s*:', line)
        if m:
            current_service = m.group(1)
            services[current_service] = {"image": "", "ports": [], "environment": [], "volumes": []}
            continue

        if current_service:
            # image
            m = re.match(r'^\s+image:\s*(.+)', line)
            if m:
                services[current_service]["image"] = m.group(1).strip()
                continue
            # ports
            m = re.match(r'^\s+-\s+["\']?(\d+(?:\.\d+\.\d+\.\d+)?:\d+):(\d+)["\']?', line)
            if m:
                services[current_service]["ports"].append((m.group(1), m.group(2)))
                continue
            # environment
            m = re.match(r'^\s+-\s+(.+=.+)', line)
            if m and "environment" in content[content.find(current_service):content.find(current_service)+500]:
                services[current_service]["environment"].append(m.group(1).strip())
                continue
            # volumes
            m = re.match(r'^\s+-\s+(.+:.+)', line)
            if m:
                services[current_service]["volumes"].append(m.group(1).strip())
                continue

# ── Emit incus-compose.yaml ───────────────────────────────────────────────────
print(f"""\
# incus-compose.yaml — generated by docker-to-incus.sh from {src_path}
# Tool: https://github.com/digizyne/incus-compose
#
# Usage:
#   incus-compose up
#   incus-compose down
#
# Each service runs as an Incus system container (full Linux OS + systemd).
# Images are pulled from images.linuxcontainers.org unless overridden.
# Set image: to a local alias built with distrobuilder + incus-image.yaml.
""")

print("services:")
for svc_name, svc in services.items():
    img = svc["image"] or f"images:ubuntu/24.04/cloud"
    # Map docker hub images to Incus image names
    if img.startswith("ubuntu"):
        ver = re.search(r"(\d+\.\d+|\d+)", img)
        img = f"images:ubuntu/{ver.group(1)}/cloud" if ver else "images:ubuntu/24.04/cloud"
    elif img.startswith("debian"):
        img = "images:debian/12/cloud"
    elif img.startswith("alpine"):
        img = "images:alpine/3.21"
    elif "rust" in img or "golang" in img or "node" in img or "bun" in img or "scratch" in img:
        img = f"local:{svc_name}"  # expects a locally built distrobuilder image
    elif not img.startswith("images:") and not img.startswith("local:") and not img.startswith("docker:"):
        img = f"docker:{img}"  # use Incus OCI support for arbitrary Docker Hub images

    print(f"  {svc_name}:")
    print(f"    image: {img}")
    print(f"    container_name: {svc_name}")

    if svc["ports"]:
        print("    devices:")
        print("      proxies:")
        for host_port, container_port in svc["ports"]:
            # host_port may be "127.0.0.1:8080" or just "8080"
            if ":" in host_port:
                listen_addr = host_port
            else:
                listen_addr = f"0.0.0.0:{host_port}"
            print(f"        - listen: tcp:{listen_addr}")
            print(f"          connect: tcp:127.0.0.1:{container_port}")

    if svc["environment"]:
        print("    environment:")
        for env in svc["environment"]:
            print(f"      - {env}")

    if svc["volumes"]:
        print("    volumes:")
        for vol in svc["volumes"]:
            parts = vol.split(":")
            src = parts[0]
            tgt = parts[1] if len(parts) > 1 else src
            ro  = "true" if len(parts) > 2 and parts[2] == "ro" else "false"
            # Named volumes → Incus volume type; host paths → disk device
            if src.startswith("/") or src.startswith("."):
                vtype = "disk"
            else:
                vtype = "volume"
            print(f"      - type: {vtype}")
            print(f"        source: {src}")
            print(f"        target: {tgt}")
            print(f"        read_only: {ro}")

    print()

PYEOF
}

# ── Per-repo processing ───────────────────────────────────────────────────────

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  budget_check "$repo" || break

  info "Scanning ${repo}..."

  # Fetch the full file tree in one call
  tree_json=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}/git/trees/HEAD?recursive=1" 2>/dev/null || true)
  if [[ -z "$tree_json" ]] || ! echo "$tree_json" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'tree' in d else 1)" 2>/dev/null; then
    warn "  Could not fetch tree for ${repo} — skipping."
    (( failed++ )) || true
    continue
  fi

  tree_paths=$(echo "$tree_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('tree', []):
    if item['type'] == 'blob':
        print(item['path'])
" 2>/dev/null || true)

  # Detect Docker artifacts
  dockerfiles=$(echo "$tree_paths" | grep -E "(^|/)Dockerfile(\.[a-zA-Z0-9_-]+)?$" || true)
  composefiles=$(echo "$tree_paths" | grep -E "(^|/)docker-compose\.(yml|yaml)$" || true)
  dockerignores=$(echo "$tree_paths" | grep -E "(^|/)\.dockerignore$" || true)

  if [[ -z "$dockerfiles" && -z "$composefiles" && -z "$dockerignores" ]]; then
    info "  No Docker artifacts — skipping."
    (( skipped++ )) || true
    continue
  fi

  # Check idempotency
  if [[ "$FORCE" != "true" ]]; then
    already_converted=$(echo "$tree_paths" | grep -E "(^|/)(incus-(image|compose)|blincus-.+)\.yaml$" || true)
    if [[ -n "$already_converted" ]]; then
      info "  Already has Incus/blincus files — skipping (use FORCE=true to regenerate)."
      (( skipped++ )) || true
      continue
    fi
  fi

  info "  Found Docker artifacts:"
  [[ -n "$dockerfiles"   ]] && echo "$dockerfiles"   | sed 's/^/    Dockerfile: /' >&2
  [[ -n "$composefiles"  ]] && echo "$composefiles"  | sed 's/^/    compose:    /' >&2
  [[ -n "$dockerignores" ]] && echo "$dockerignores" | sed 's/^/    ignore:     /' >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  [dry-run] Would convert ${repo}."
    (( converted++ )) || true
    continue
  fi

  # ── Convert each Dockerfile ────────────────────────────────────────────────
  while IFS= read -r dockerfile_path; do
    [[ -z "$dockerfile_path" ]] && continue
    dir=$(dirname "$dockerfile_path")
    [[ "$dir" == "." ]] && dir=""
    component=$(basename "${dir:-$repo}")

    info "  Converting ${dockerfile_path} → ${dir:+$dir/}incus-image.yaml"

    dockerfile_content=$(get_file_content "$repo" "$dockerfile_path")
    dockerfile_sha=$(get_file_sha "$repo" "$dockerfile_path")

    # Generate distrobuilder YAML from Dockerfile content
    incus_image_yaml=$(generate_incus_image "$repo" "$component" "$dockerfile_content" "$dockerfile_path")

    # Write incus-image.yaml
    incus_image_path="${dir:+$dir/}incus-image.yaml"
    existing_sha=$(get_file_sha "$repo" "$incus_image_path" || true)
    encoded=$(echo "$incus_image_yaml" | b64_encode)
    put_file "$repo" "$incus_image_path" \
      "chore(incus): add distrobuilder image definition for ${component}" \
      "$encoded" "$existing_sha" \
      && info "    Wrote ${incus_image_path}" \
      || { warn "    Failed to write ${incus_image_path}"; (( failed++ )) || true; continue; }

    # Write blincus cloud-init template alongside incus-image.yaml
    blincus_template_path="${dir:+$dir/}blincus-${component}.yaml"
    blincus_yaml=$(generate_blincus_template "$repo" "$component" "$dockerfile_content" "$dockerfile_path")
    existing_blincus_sha=$(get_file_sha "$repo" "$blincus_template_path" || true)
    encoded_blincus=$(echo "$blincus_yaml" | b64_encode)
    put_file "$repo" "$blincus_template_path" \
      "chore(incus): add blincus cloud-init template for ${component}" \
      "$encoded_blincus" "$existing_blincus_sha" \
      && info "    Wrote ${blincus_template_path}" \
      || warn "    Failed to write ${blincus_template_path}"

    # Delete Dockerfile
    delete_file "$repo" "$dockerfile_path" \
      "chore(incus): remove Dockerfile (replaced by incus-image.yaml + blincus template)" \
      "$dockerfile_sha" \
      && info "    Deleted ${dockerfile_path}" \
      || warn "    Failed to delete ${dockerfile_path}"

    # Delete .dockerignore in same directory if present
    ignore_path="${dir:+$dir/}.dockerignore"
    ignore_sha=$(get_file_sha "$repo" "$ignore_path" || true)
    if [[ -n "$ignore_sha" ]]; then
      delete_file "$repo" "$ignore_path" \
        "chore(incus): remove .dockerignore (not needed for distrobuilder)" \
        "$ignore_sha" \
        && info "    Deleted ${ignore_path}" \
        || warn "    Failed to delete ${ignore_path}"
    fi
  done <<< "$dockerfiles"

  # ── Convert each docker-compose file ──────────────────────────────────────
  while IFS= read -r compose_path; do
    [[ -z "$compose_path" ]] && continue
    dir=$(dirname "$compose_path")
    [[ "$dir" == "." ]] && dir=""

    info "  Converting ${compose_path} → ${dir:+$dir/}incus-compose.yaml"

    compose_content=$(get_file_content "$repo" "$compose_path")
    compose_sha=$(get_file_sha "$repo" "$compose_path")

    # Generate incus-compose.yaml
    incus_compose_yaml=$(generate_incus_compose "$repo" "$compose_content" "$compose_path")

    incus_compose_path="${dir:+$dir/}incus-compose.yaml"
    existing_sha=$(get_file_sha "$repo" "$incus_compose_path" || true)
    encoded=$(echo "$incus_compose_yaml" | b64_encode)
    put_file "$repo" "$incus_compose_path" \
      "chore(incus): add incus-compose definition (converted from docker-compose)" \
      "$encoded" "$existing_sha" \
      && info "    Wrote ${incus_compose_path}" \
      || { warn "    Failed to write ${incus_compose_path}"; (( failed++ )) || true; continue; }

    # Delete docker-compose file
    delete_file "$repo" "$compose_path" \
      "chore(incus): remove docker-compose.yml (replaced by incus-compose.yaml)" \
      "$compose_sha" \
      && info "    Deleted ${compose_path}" \
      || warn "    Failed to delete ${compose_path}"
  done <<< "$composefiles"

  (( converted++ )) || true
  info "  Done: ${repo}"

done <<< "$REPOS"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  docker-to-incus complete"
echo "  Converted: ${converted}"
echo "  Skipped:   ${skipped}"
echo "  Failed:    ${failed}"
echo "════════════════════════════════════════"

budget_report

[[ "$failed" -gt 0 ]] && exit 1 || exit 0
