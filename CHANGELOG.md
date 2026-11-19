# Changelog

All notable OTA releases are documented here. Entries are prepended
automatically by `ota-release.yml` when a new semver tag is pushed.

Format: `## vX.Y.Z — YYYY-MM-DD`

---

## v1.1.0 — 2026-06-17

### AI cost tracking + agent price sync

Adds OCU-based AI session budgeting and a hybrid A/B/C price-sync pipeline
that pulls live model pricing from LiteLLM, Anthropic API, and a static
fallback, with staleness detection and automatic re-sync.

- `config/ai-agent-costs.yml` — per-model OCU budgets and session limits
- `scripts/sync-agent-prices.sh` — A/B/C price sync with staleness check
- `DOCS/ai-agent-costs.md` — tokenizer reference and cost model documentation
- `scripts/includes/llm.sh` — shared LLM cost helpers for scripts

### OTA reconcile system

Hybrid A/B/C fallback layer between template sync and OTA delivery. Runs
weekly and autonomously selects a recovery path per consumer repo based on
`.ota/version` SHA, open PR state, and `OTA_SYNC_INCOMPLETE` variable.

- Path A (stamp): version is current — write `.ota/version` stamp, no PR
- Path B (drift PR): version is stale — open a drift-correction PR
- Path C (quota-recovery PR): `OTA_SYNC_INCOMPLETE=true` — open a recovery PR

New: `scripts/ota-reconcile.sh`, `.github/workflows/ota-reconcile.yml`,
`DOCS/ota-reconcile.md`, `config/ota-blocklist.yml` `reconcile_eligible_profiles`.

### PR/MR lifecycle quota + queue guard

Shared protection layer for all PR/MR-creating workflows covering both
incoming PRs to fork-sync-all and outbound PRs to consumer repos.

- `scripts/includes/pr-lifecycle.sh` — defer/resume pattern: on quota
  exhaustion mid-loop, writes remaining items to a repo Actions variable
  and re-dispatches the calling workflow for the next quota window
- `pr-lifecycle-guard.yml` — reusable `workflow_call` guard exposing
  `proceed` and `quota_remaining` outputs; called by OTA Release,
  Upstream PRs, and Rebase PRs
- `pr-gate.yml` — required status check for incoming PRs; posts a single
  explanatory comment when quota is exhausted (deduped, no spam)
- `pre-flush-prep.yml` — quota pre-flight now exits 1 on low quota so
  `rate-limit-rerun.yml` detects and retries it automatically

### Vouch trust management + SBOM pipeline

Contributor trust management and a four-stage SBOM pipeline.

- `.github/VOUCHED.td` — trusted contributors for this repo
- `.github/VOUCHED-upstreams.td` — all 113+ upstream orgs from
  `registered-imports.json`, seeded and kept current
- `scripts/vouch-check-pr.sh` — hybrid A/B/C PR gate (denounced/blocked/warned)
- `scripts/vouch-seed.sh` — bootstrap VOUCHED.td from org members + git log
- `vouch-check-pr.yml`, `vouch-manage.yml`, `vouch-sync-codeowners.yml`
- `generate-sbom.yml` — Trivy → sbomasm → parlay → sbomqs four-stage pipeline
- SBOM asset attached to every OTA release via `ota-release.yml`
- `validate-registered-imports.py --vouch-check` — advisory upstream org audit

### Platform hardening + pipeline improvements

- Self-hosted git platform support (Gitea, Forgejo, Codeberg) via
  `scripts/includes/platform-adapter.sh`
- `flush-active-watchdog.yml` + `FLUSH_ACTIVE` TTL hardening
- `flush-lifecycle.yml` — orchestrates pre-flush → flush → post-flush chain
- `quota-snapshot.sh` centralised pre-flight across all flush-chain workflows
- `runner-status.yml` + quota snapshot at all flush-chain entry/exit points
- `pipeline-guard.sh` — prevents concurrent flush runs
- Eco-CI energy estimation across all CI platforms (REUSE compliance)
- Interactive GitBook framework + FSA branding
- Timezone registry expanded to all 484 IANA zones
- `actions/checkout` upgraded to v6 across all 124 workflows

### Infrastructure

- Ona Projects MCP server (`scripts/ona-mcp-server.py`) — exposes project
  operations as MCP tools on port 8788
- `sync-ona-projects.yml` — daily project sync
- `update-quota-costs.yml` Phase 2 — observed p50/p95 values replace
  code-audit estimates for 19 instrumented workflows

**Full release notes:** https://github.com/Interested-Deving-1896/fork-sync-all/releases/tag/v1.1.0

---

## v1.0.0 — 2026-05-27

### Initial OTA system release

Introduces the opt-in OTA update system for forks of fork-sync-all and
OSP-bound consumer repos.

**What's included in OTA payloads:**
- Repo-own source code and directory structure (per-repo, assembled at delivery time)
- Repo-own GitHub Actions workflows (anything not managed by template sync)
- OTA self-update machinery (`ota-opt-in.yml`, `ota-self-update.yml`)

**What OTA does NOT touch:**
- Shared infra workflows managed by template sync (defined in `config/template-manifest.yml`)
- `.ota/config.yml` fields managed automatically (`pinned_sha`, `pinned_at`, `ota_version`)
- Files listed in a repo's `exclude_paths`

**Mirror-chain exclusion:**
- `Interested-Deving-1896`, `OpenOS-Project-OSP`, `OpenOS-Project-Ecosystem-OOC`,
  `gitlab.com/openos-project` are excluded from OTA delivery by default
- Non-standalone profile consumers (`full`, `mirror`, `infra-core`) are excluded by default
- Both exclusions can be overridden with `mirror_chain_opt_in: true` in `.ota/config.yml`

**To opt in:** run the `OTA Opt-In` workflow_dispatch in your fork.

**Full release notes:** https://github.com/Interested-Deving-1896/fork-sync-all/releases/tag/v1.0.0
