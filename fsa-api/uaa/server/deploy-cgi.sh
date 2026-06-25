#!/usr/bin/env bash
# server/deploy-cgi.sh — deploy adapter scripts as Apache CGI endpoints
#
# Reads config/routes.yml and symlinks each adapter script into the CGI
# directory so Apache mod_cgi can serve them. Mirrors the bash-api-server
# pattern from Lifailon/bash-api-server.
#
# Usage: ./server/deploy-cgi.sh [CGI_DIR]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/log.sh"

CGI_DIR="${1:-/usr/lib/cgi-bin/uaa}"
mkdir -p "$CGI_DIR"

ROUTES_FILE="$REPO_ROOT/config/routes.yml"
[[ -f "$ROUTES_FILE" ]] || { error "config/routes.yml not found"; exit 1; }

# Parse routes.yml: each route has a path and a script field
python3 - "$ROUTES_FILE" "$CGI_DIR" "$REPO_ROOT" << 'PYEOF'
import yaml, sys, os, stat

routes_file, cgi_dir, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(routes_file) as f:
    config = yaml.safe_load(f)

for route in config.get('routes', []):
    script_rel = route.get('script', '')
    script_abs = os.path.join(repo_root, script_rel)
    if not os.path.isfile(script_abs):
        print(f"[warn] script not found: {script_rel}", file=sys.stderr)
        continue
    # Make executable
    st = os.stat(script_abs)
    os.chmod(script_abs, st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    # Symlink into CGI dir
    cgi_name = route.get('cgi_name', os.path.basename(script_abs))
    link = os.path.join(cgi_dir, cgi_name)
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(script_abs, link)
    print(f"  linked {script_rel} -> {link}")
PYEOF

info "CGI deployment complete: $CGI_DIR"
