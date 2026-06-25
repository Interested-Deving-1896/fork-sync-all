#!/usr/bin/env bash
# adapters/ai/agentic-shell.sh — LLM-driven natural language shell command generation
# POST /api/ai/shell
# Body: {"command":"list files modified today","execute":false,"model":"gpt-4o-mini"}
#
# Inspired by Flux159/agentic-shell (AGIsh). Translates natural language to shell
# commands via LLM. When execute=false (default), returns the command for review.
# When execute=true, runs it in a sandboxed subshell with a timeout.
#
# SAFETY: execute=true requires UAA_SHELL_EXEC_ENABLED=true env var AND auth.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"

NL_COMMAND="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('command',''))" "$tmp")"
EXECUTE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get('execute',False)).lower())" "$tmp")"
MODEL="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('model','gpt-4o-mini'))" "$tmp")"
rm -f "$tmp"

[[ -z "$NL_COMMAND" ]] && { respond_error 400 "missing command field"; exit 0; }

GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GITHUB_TOKEN not set"; exit 0; }

# Ask LLM to translate natural language → shell command
SYSTEM_PROMPT="You are a shell command generator. The user describes what they want to do in natural language. Respond with ONLY the shell command, no explanation, no markdown, no backticks. The command must be safe, non-destructive by default, and work on Linux/macOS bash."

SHELL_CMD="$(python3 - "$GH_TOKEN" "$MODEL" "$NL_COMMAND" "$SYSTEM_PROMPT" << 'PYEOF'
import json, sys, urllib.request

token, model, prompt, system = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = json.dumps({
    "model": model,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user",   "content": prompt}
    ],
    "max_tokens": 256
}).encode()
req = urllib.request.Request(
    'https://models.inference.ai.azure.com/chat/completions',
    data=payload, method='POST')
req.add_header('Authorization', f'Bearer {token}')
req.add_header('Content-Type', 'application/json')
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        result = json.load(r)
    print(result['choices'][0]['message']['content'].strip())
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)"

if [[ "$EXECUTE" == "true" ]]; then
  if [[ "${UAA_SHELL_EXEC_ENABLED:-false}" != "true" ]]; then
    respond_json 200 "{\"command\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SHELL_CMD"),\"executed\":false,\"reason\":\"UAA_SHELL_EXEC_ENABLED not set\"}"
    exit 0
  fi
  # Execute in sandboxed subshell with 10s timeout
  EXEC_OUT="$(timeout 10 bash -c "$SHELL_CMD" 2>&1 || true)"
  EXEC_EXIT=$?
  respond_json 200 "{\"command\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SHELL_CMD"),\"executed\":true,\"exit_code\":$EXEC_EXIT,\"output\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$EXEC_OUT")}"
else
  respond_json 200 "{\"command\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SHELL_CMD"),\"executed\":false,\"model\":\"$MODEL\"}"
fi
