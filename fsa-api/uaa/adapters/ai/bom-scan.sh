#!/usr/bin/env bash
# adapters/ai/bom-scan.sh — AI Bill of Materials scanner
# POST /api/ai/bom/scan
# Body: {"path":".","format":"cyclonedx|sarif|spdx|json","output_file":""}
#
# Wraps Trusera/ai-bom. Falls back to a lightweight built-in scanner if
# ai-bom is not installed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
tmp="$(mktemp)"
echo "${body:-{}}" > "$tmp"

SCAN_PATH="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('path','.'))" "$tmp")"
FORMAT="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('format','json'))" "$tmp")"
OUTPUT_FILE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('output_file',''))" "$tmp")"
rm -f "$tmp"

abs_scan="$(realpath "$SCAN_PATH" 2>/dev/null || echo "$SCAN_PATH")"
[[ ! -d "$abs_scan" ]] && { respond_error 404 "path not found: $SCAN_PATH"; exit 0; }

if command -v ai-bom &>/dev/null; then
  # Use Trusera/ai-bom if installed
  out_tmp="$(mktemp --suffix=".${FORMAT}")"
  ai-bom scan --path "$abs_scan" --format "$FORMAT" --output "$out_tmp" 2>/dev/null || true
  result="$(cat "$out_tmp" 2>/dev/null || echo '{}')"
  rm -f "$out_tmp"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$result" > "$OUTPUT_FILE"
    respond_json 200 "{\"status\":\"ok\",\"tool\":\"ai-bom\",\"format\":\"$FORMAT\",\"output_file\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$OUTPUT_FILE")}"
  else
    # Return inline (may be large)
    printf '%s' "$result"
  fi
else
  # Built-in lightweight scanner: detect AI SDK imports across common languages
  python3 - "$abs_scan" "$FORMAT" << 'PYEOF'
import os, sys, json, re

scan_path, fmt = sys.argv[1], sys.argv[2]

AI_PATTERNS = {
    "openai":      r'openai|from openai|import openai',
    "anthropic":   r'anthropic|from anthropic',
    "langchain":   r'langchain|from langchain',
    "huggingface": r'transformers|from transformers|huggingface_hub',
    "ollama":      r'ollama|from ollama',
    "github-models": r'models\.inference\.ai\.azure\.com',
    "cohere":      r'cohere|from cohere',
    "mistral":     r'mistralai|from mistralai',
    "groq":        r'groq|from groq',
    "vertexai":    r'vertexai|google\.cloud\.aiplatform',
}

findings = []
for root, dirs, files in os.walk(scan_path):
    dirs[:] = [d for d in dirs if d not in {'.git','node_modules','__pycache__','.venv','venv'}]
    for fname in files:
        if not any(fname.endswith(ext) for ext in ['.py','.js','.ts','.go','.rb','.rs','.sh']):
            continue
        fpath = os.path.join(root, fname)
        try:
            content = open(fpath, errors='ignore').read()
        except OSError:
            continue
        for sdk, pattern in AI_PATTERNS.items():
            if re.search(pattern, content, re.IGNORECASE):
                rel = os.path.relpath(fpath, scan_path)
                findings.append({"sdk": sdk, "file": rel})

# Deduplicate by sdk
seen = {}
for f in findings:
    seen.setdefault(f['sdk'], []).append(f['file'])

components = [{"sdk": sdk, "files": files, "count": len(files)}
              for sdk, files in sorted(seen.items())]

print(json.dumps({
    "tool": "uaa-builtin-scanner",
    "format": fmt,
    "scan_path": scan_path,
    "components": components,
    "total_sdks": len(components),
    "note": "Install ai-bom (pip install ai-bom) for full CycloneDX/SARIF/SPDX output"
}, indent=2))
PYEOF
fi
