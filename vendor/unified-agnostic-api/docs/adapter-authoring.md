# Adapter Authoring Guide

An adapter is a directory under `adapters/` containing one or more bash scripts,
each implementing a single API endpoint.

## Minimal adapter

```
adapters/my-adapter/
├── manifest.yml      # adapter metadata
├── my-endpoint.sh    # one script per endpoint
└── README.md         # optional
```

## Script contract

```bash
#!/usr/bin/env bash
# adapters/my-adapter/my-endpoint.sh
# GET /api/my-adapter/endpoint?param=value
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"   # provides query_param, respond_json, auth_check, etc.

# 1. Read inputs
VALUE="$(query_param param "default")"

# 2. Do work (stdout is the response body)
result="some output"

# 3. Emit response
respond_json 200 "{\"value\":\"$result\"}"
```

**Rules:**
- All logging → `stderr` via `info()`, `warn()`, `error()` from `lib/log.sh`
- All response output → `stdout` via `respond_json` / `respond_text`
- Exit 0 = success (HTTP 200), exit non-zero = server error (HTTP 500)
- Use `mktemp` for any multi-field JSON input — never inline bash variables into Python strings
- Use `auth_check` at the top of any write/mutating endpoint

## manifest.yml fields

```yaml
name: my-adapter
description: One sentence describing what this adapter does
version: 0.1.0
upstream:
  - owner/repo   # upstream projects this adapter draws from
env:
  MY_TOKEN: "Description of what this env var does"
```

## Registering a route

Add an entry to `config/routes.yml`:

```yaml
- path: /api/my-adapter/endpoint
  script: adapters/my-adapter/my-endpoint.sh
  method: GET          # GET | POST | PUT | DELETE | ANY
  auth: false          # true = require UAA_AUTH bearer token
```

## Input helpers (from lib/adapter.sh)

| Helper | Description |
|---|---|
| `query_param KEY [DEFAULT]` | Read `?key=value` from query string |
| `require_param KEY` | Read param, exit 400 if missing |
| `request_body` | Read full POST body from stdin |
| `path_var INDEX` | Extract path segment from `$REQUEST_URI` |
| `auth_check` | Validate bearer token (no-op if `UAA_AUTH` unset) |

## Response helpers (from lib/http.sh)

| Helper | Description |
|---|---|
| `respond_json STATUS BODY` | Emit JSON response |
| `respond_text STATUS BODY` | Emit plain text response |
| `respond_error STATUS MSG` | Emit `{"error":"..."}` JSON |
| `json_field KEY JSON` | Extract a field from a JSON string |

## Testing locally

```bash
# Direct script invocation (no server needed)
export v_path=/tmp
bash adapters/filesystem/ls.sh

# Via CLI
./cli/uaa.sh filesystem ls --path /tmp

# Via running server
curl http://localhost:8080/api/filesystem/ls?path=/tmp
```
