# fsa-api — Fork-Sync-All API

A two-layer API system:

```
fsa-api/
  uaa/        — Unified Agnostic API (generic, reusable by any consumer repo)
  core/       — FSA-specific adapter layer (extends UAA for fork-sync-all)
  config/     — FSA route manifest + feature toggles
  server/     — FSA HTTP server (UAA server + FSA routes)
  cli/        — fsa CLI (local + remote dispatch)
```

## Architecture

```
Consumer repo                    fork-sync-all
─────────────                    ─────────────
fsa-api/uaa/          copy →     fsa-api/uaa/        (generic adapters)
my-api/core/          own  →     fsa-api/core/       (FSA-specific adapters)
my-api/config/        own  →     fsa-api/config/     (routes + toggles)
```

**`uaa/`** is the generic foundation — platform-agnostic adapters for GitHub,
filesystem, AI, browser, OS. Consumer repos copy this as-is and build their
own `core/` on top. It has no knowledge of fork-sync-all.

**`core/`** is the FSA-specific layer — adapters that expose fork-sync-all's
control plane as HTTP endpoints: workflow dispatch, repo management, mirror
chain status, quota monitoring, notification triage, feature toggles.

## Quick start

```bash
# Start the FSA API server (port 8080)
bash fsa-api/server/fsa-start.sh

# Or use the CLI directly (no server needed)
bash fsa-api/cli/fsa.sh workflow list
bash fsa-api/cli/fsa.sh workflow run sync-forks
bash fsa-api/cli/fsa.sh quota status
bash fsa-api/cli/fsa.sh chain status
bash fsa-api/cli/fsa.sh toggle list
bash fsa-api/cli/fsa.sh toggle set sync-forks enabled
```

## HTTP API

```
GET  /api/fsa/workflows              — list all workflows + status
POST /api/fsa/workflows/:name/run    — dispatch a workflow
GET  /api/fsa/workflows/:name/status — last run status
GET  /api/fsa/repos                  — list org repos
POST /api/fsa/repos/onboard          — onboard a new repo
GET  /api/fsa/chain/status           — mirror chain status
POST /api/fsa/chain/flush            — trigger full chain flush
GET  /api/fsa/quota                  — current quota status
GET  /api/fsa/notifications          — unread notifications
POST /api/fsa/notifications/triage   — auto-triage known-safe noise
GET  /api/fsa/toggles                — list feature toggles
POST /api/fsa/toggles/:name          — set toggle value

# Generic UAA endpoints (pass-through)
GET  /api/github/repos               — list GitHub repos
GET  /api/github/orgs                — list GitHub orgs
GET  /health                         — server health
GET  /api/meta/routes                — all registered routes
```

## Consumer repo usage

To use UAA in your own repo:

1. Copy `fsa-api/uaa/` into your repo as `my-api/uaa/`
2. Create `my-api/core/adapters/` with your platform-specific adapters
3. Create `my-api/config/routes.yml` extending `uaa/config/routes.yml`
4. Start with `bash my-api/server/start.sh`

`fsa-api/core/` is the reference implementation showing how to extend UAA.

## Workflow dispatch via API

```bash
# Dispatch any FSA workflow
curl -X POST http://localhost:8080/api/fsa/workflows/sync-forks/run \
  -H "Content-Type: application/json" \
  -d '{"inputs": {}}'

# With inputs
curl -X POST http://localhost:8080/api/fsa/workflows/generate-notebooklm/run \
  -H "Content-Type: application/json" \
  -d '{"inputs": {"backend": "open-notebook", "content_types": "audio-overview"}}'
```

## Feature toggles

Toggles live in `fsa-api/config/fsa-toggles.yml` and are also stored as
GitHub Actions repo variables (`FSA_TOGGLE_*`) so they persist across runs.

```bash
# List all toggles
bash fsa-api/cli/fsa.sh toggle list

# Enable/disable a workflow
bash fsa-api/cli/fsa.sh toggle set notify-manager enabled
bash fsa-api/cli/fsa.sh toggle set translate-readmes disabled
```
