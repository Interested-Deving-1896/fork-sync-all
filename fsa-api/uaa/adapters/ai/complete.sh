#!/usr/bin/env bash
# adapters/ai/complete.sh — LLM text completion via GitHub Models API
# POST /api/ai/complete
# Body: {"prompt":"...","model":"gpt-4o-mini","provider":"github|openai|anthropic","system":"..."}
#
# Uses the same llm_call() pattern as scripts/includes/llm.sh in fork-sync-all.
# Provider routing: github (default, uses GITHUB_TOKEN), openai, anthropic.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"

python3 - "$tmp" \
  "${GITHUB_TOKEN:-}" \
  "${OPENAI_API_KEY:-}" \
  "${ANTHROPIC_API_KEY:-}" << 'PYEOF'
import json, sys, os, urllib.request, urllib.error

tmp_file = sys.argv[1]
gh_token, openai_key, anthropic_key = sys.argv[2], sys.argv[3], sys.argv[4]

with open(tmp_file) as f:
    req = json.load(f)
os.unlink(tmp_file)

prompt   = req.get('prompt', '')
model    = req.get('model', 'gpt-4o-mini')
provider = req.get('provider', 'github')
system   = req.get('system', 'You are a helpful assistant.')
max_tok  = req.get('max_tokens', 1024)

if not prompt:
    print(json.dumps({"error": "missing prompt"}))
    sys.exit(0)

messages = [
    {"role": "system", "content": system},
    {"role": "user",   "content": prompt}
]

def call_openai_compat(url, token, model, messages, max_tokens):
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens
    }).encode()
    request = urllib.request.Request(url, data=payload, method='POST')
    request.add_header('Authorization', f'Bearer {token}')
    request.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(request, timeout=60) as r:
        return json.load(r)

try:
    if provider == 'github':
        if not gh_token:
            print(json.dumps({"error": "GITHUB_TOKEN not set"})); sys.exit(0)
        result = call_openai_compat(
            'https://models.inference.ai.azure.com/chat/completions',
            gh_token, model, messages, max_tok)
    elif provider == 'openai':
        if not openai_key:
            print(json.dumps({"error": "OPENAI_API_KEY not set"})); sys.exit(0)
        result = call_openai_compat(
            'https://api.openai.com/v1/chat/completions',
            openai_key, model, messages, max_tok)
    elif provider == 'anthropic':
        if not anthropic_key:
            print(json.dumps({"error": "ANTHROPIC_API_KEY not set"})); sys.exit(0)
        payload = json.dumps({
            "model": model,
            "max_tokens": max_tok,
            "system": system,
            "messages": [{"role": "user", "content": prompt}]
        }).encode()
        request = urllib.request.Request(
            'https://api.anthropic.com/v1/messages', data=payload, method='POST')
        request.add_header('x-api-key', anthropic_key)
        request.add_header('anthropic-version', '2023-06-01')
        request.add_header('Content-Type', 'application/json')
        with urllib.request.urlopen(request, timeout=60) as r:
            result = json.load(r)
        text = result.get('content', [{}])[0].get('text', '')
        print(json.dumps({"provider": provider, "model": model,
                          "text": text, "usage": result.get('usage', {})}))
        sys.exit(0)
    else:
        print(json.dumps({"error": f"unknown provider: {provider}"})); sys.exit(0)

    text = result.get('choices', [{}])[0].get('message', {}).get('content', '')
    usage = result.get('usage', {})
    print(json.dumps({"provider": provider, "model": model,
                      "text": text, "usage": usage}, indent=2))

except urllib.error.HTTPError as e:
    try:
        err = json.load(e)
    except Exception:
        err = {"message": str(e)}
    print(json.dumps({"error": err.get('message', str(e)), "code": e.code}))
except Exception as e:
    print(json.dumps({"error": str(e)}))
PYEOF
