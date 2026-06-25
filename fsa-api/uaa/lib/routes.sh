#!/usr/bin/env bash
# lib/routes.sh — route manifest parser
#
# Reads config/routes.yml and emits backend-specific argument lists.
# Called by server/start.sh to build the shell2http or webhook invocation.

[[ -n "${_UAA_ROUTES_LOADED:-}" ]] && return 0
_UAA_ROUTES_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log.sh"

# routes_to_shell2http_args ROUTES_FILE
# Emits one argument per line: alternating PATH SCRIPT pairs for shell2http.
routes_to_shell2http_args() {
  local routes_file="$1"
  python3 - "$routes_file" "$REPO_ROOT" << 'PYEOF'
import yaml, sys, os

routes_file, repo_root = sys.argv[1], sys.argv[2]
with open(routes_file) as f:
    config = yaml.safe_load(f)

for route in config.get('routes', []):
    path   = route.get('path', '')
    script = route.get('script', '')
    method = route.get('method', 'GET').upper()
    if not path or not script:
        continue
    script_abs = os.path.join(repo_root, script)
    if not os.path.isfile(script_abs):
        print(f"[warn] script not found: {script}", file=sys.stderr)
        continue
    # shell2http format: /path "script args"
    # Method filtering is done inside the script via $REQUEST_METHOD
    print(path)
    print(f'bash {script_abs}')
PYEOF
}

# routes_to_hooks_json ROUTES_FILE — emit webhook hooks.json
routes_to_hooks_json() {
  local routes_file="$1"
  python3 - "$routes_file" "$REPO_ROOT" << 'PYEOF'
import yaml, sys, os, json

routes_file, repo_root = sys.argv[1], sys.argv[2]
with open(routes_file) as f:
    config = yaml.safe_load(f)

hooks = []
for route in config.get('routes', []):
    hook_id = route.get('path', '').lstrip('/').replace('/', '-')
    script  = route.get('script', '')
    script_abs = os.path.join(repo_root, script)
    if not hook_id or not script:
        continue
    hooks.append({
        "id": hook_id,
        "execute-command": script_abs,
        "command-working-directory": repo_root,
        "response-message": "queued",
        "trigger-rule": {
            "match": {
                "type": "value",
                "value": route.get('secret', ''),
                "parameter": {"source": "header", "name": "X-Hook-Secret"}
            }
        } if route.get('secret') else {}
    })

print(json.dumps(hooks, indent=2))
PYEOF
}
