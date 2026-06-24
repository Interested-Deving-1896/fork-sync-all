# Glossary

> Auto-generated 2026-06-23 by `scripts/generate-book-pages.py`

Definitions for every term, acronym, and concept used across fork-sync-all.

---

## Index

**A:** [ACTOR_TZ](#actor_tz) · [AGENTS.md](#agentsmd) · [autonomous mode](#autonomous-mode)  
**B:** [book-engine](#book-engine) · [brand.yml](#brandyml) · [budget.sh](#budgetsh)  
**C:** [chain position](#chain-position) · [consumer repo](#consumer-repo) · [critical-deploy](#critical-deploy)  
**D:** [DRY_RUN](#dry_run)  
**E:** [Etc/GMT+N](#etcgmt+n)  
**F:** [FSA API](#fsa-api) · [fsa-mode.sh](#fsa-modesh) · [fsa-node-identity.sh](#fsa-node-identitysh) · [full-chain-flush](#full-chain-flush)  
**G:** [generate-book-pages.py](#generate-book-pagespy) · [gh-api.sh](#gh-apish) · [GitLab subgroup](#gitlab-subgroup) · [GraphQL](#graphql) · [GROUP_SORT_KEYS](#group_sort_keys)  
**I:** [IANA timezone](#iana-timezone) · [infra-core profile](#infra-core-profile)  
**M:** [managed mode](#managed-mode) · [MCP server](#mcp-server) · [mdBook](#mdbook) · [MIN_QUOTA](#min_quota) · [mirror chain](#mirror-chain)  
**N:** [node identity](#node-identity)  
**O:** [OOC](#ooc) · [OSP](#osp) · [OSP-bound repo](#osp-bound-repo) · [OTA](#ota)  
**P:** [platform-adapter.sh](#platform-adaptersh) · [pre-flush-prep](#pre-flush-prep) · [priority tiers](#priority-tiers)  
**Q:** [queue-manager](#queue-manager) · [quota-reserve](#quota-reserve) · [quota-snapshot.sh](#quota-snapshotsh)  
**R:** [registered-imports.json](#registered-importsjson)  
**S:** [SUMMARY.md](#summarymd) · [SYNC_TOKEN](#sync_token)  
**T:** [template-manifest.yml](#template-manifestyml) · [time_format.py](#time_formatpy)  
**V:** [vendor/](#vendor)  
**W:** [workflow-quota-costs.yml](#workflow-quota-costsyml) · [WORLD_ZONES](#world_zones)  

---

<dl class="fsa-glossary">

<dt id="actor_tz">ACTOR_TZ</dt>
<dd>IANA timezone of the person who triggered a workflow. Set via `ACTOR_TZ`, `TRIGGERER_TZ`, or `GITHUB_ACTOR_TZ` env vars. Highlighted in world_table() output.</dd>

<dt id="agentsmd">AGENTS.md</dt>
<dd>Convention file for AI agents working in this repo. Defines logging rules, YAML-safe shell patterns, quota management, workflow patterns, and known pitfalls.</dd>

<dt id="autonomous-mode">autonomous mode</dt>
<dd>Operating mode when fork-sync-all is not present alongside a consumer repo. Bundled workflows activate and self-manage, scoped to the repo's own owner.</dd>

<dt id="book-engine">book-engine</dt>
<dd>Agnostic documentation export backend in `vendor/book-engine/`. Supports mdBook, MkDocs, Docusaurus, GitBook CLI, and Pandoc from a single Markdown source.</dd>

<dt id="brandyml">brand.yml</dt>
<dd>Single source of truth for fork-sync-all branding: logo URL, color palette, substitution tokens (`{{FSA_NAME}}` etc.), and book theme settings.</dd>

<dt id="budgetsh">budget.sh</dt>
<dd>Shared include providing `budget_init`, `budget_check`, `budget_report`, `osp_priority_repos`, and `workflow_min_quota`. Reads per-workflow `min_quota` from `workflow-quota-costs.yml`.</dd>

<dt id="chain-position">chain position</dt>
<dd>Where a fork-sync-all instance sits in the mirror chain: `source` (Interested-Deving-1896), `mirror` (OSP/OOC), or `downstream-fork` (independent fork).</dd>

<dt id="consumer-repo">consumer repo</dt>
<dd>Any repo that receives template files from fork-sync-all via `sync-template.sh`. Defined in `config/template-consumers.yml`.</dd>

<dt id="critical-deploy">critical-deploy</dt>
<dd>Fast-lane workflow for emergency deployments: commit + push → aggressive queue clear → priority dispatch. Manual trigger only.</dd>

<dt id="dry_run">DRY_RUN</dt>
<dd>Environment variable flag. When `true`, scripts print what they would do without making any changes. Supported by all major scripts.</dd>

<dt id="etcgmt+n">Etc/GMT+N</dt>
<dd>IANA timezone notation where the sign is inverted from UTC offset convention. `Etc/GMT+5` = UTC-5 (EST). All 484 IANA zones are included in `time_format.py`.</dd>

<dt id="fsa-api">FSA API</dt>
<dd>The `ona-mcp-server.py` MCP server exposing 5 tools: `list_projects`, `get_project`, `create_environment`, `sync_projects`, `get_config_summary`. Runs on port 8788.</dd>

<dt id="fsa-modesh">fsa-mode.sh</dt>
<dd>Three-tier managed/autonomous detection: (B) `FSA_MANAGED` repo variable → (A) GET `/repos/{owner}/fork-sync-all` → (C) token owner's fork-sync-all existence.</dd>

<dt id="fsa-node-identitysh">fsa-node-identity.sh</dt>
<dd>Extends fsa-mode.sh with chain position detection. Exports `FSA_NODE_POSITION`, `FSA_NODE_OWNER`, `FSA_UPSTREAM_OWNER`, `FSA_CHAIN_DEPTH`.</dd>

<dt id="full-chain-flush">full-chain-flush</dt>
<dd>End-to-end pipeline: pre-flush-prep → mirror chain → post-flush-prep. Triggered manually or by critical-deploy.</dd>

<dt id="generate-book-pagespy">generate-book-pages.py</dt>
<dd>Script that generates `DOCS/generated/` pages from live config sources. Also injects index + glossary into workflow-triggers.md.</dd>

<dt id="gh-apish">gh-api.sh</dt>
<dd>Shared include providing `gh_api`, `gh_get`, `gh_api_graphql`, `merge_upstream`, `get_default_sha`. All status messages use `>&2`.</dd>

<dt id="gitlab-subgroup">GitLab subgroup</dt>
<dd>Organizational unit in the `openos-project` GitLab group. Defined in `config/gitlab-subgroups.yml`. 14 subgroups covering ~225 repos.</dd>

<dt id="graphql">GraphQL</dt>
<dd>Preferred over paginated REST for any loop fetching the same data for multiple repos. Counts as 1 REST call regardless of how many repos are queried.</dd>

<dt id="group_sort_keys">GROUP_SORT_KEYS</dt>
<dd>Dict in `generate-workflow-triggers-doc.py` mapping group names to filename-substring lists for non-alphabetical display ordering.</dd>

<dt id="iana-timezone">IANA timezone</dt>
<dd>Standard timezone identifier from the IANA Time Zone Database (e.g. `America/Toronto`, `Europe/Paris`). `time_format.py` covers all 484 zones.</dd>

<dt id="infra-core-profile">infra-core profile</dt>
<dd>Template profile providing CI hygiene + autonomous-fallback workflows. Includes PR automation, token rotation, branch cleanup, mdBook workflows, OTA, accessibility.</dd>

<dt id="managed-mode">managed mode</dt>
<dd>Default operating mode when fork-sync-all is present. Bundled autonomous-fallback workflows detect this and skip themselves.</dd>

<dt id="mcp-server">MCP server</dt>
<dd>Model Context Protocol server. `ona-mcp-server.py` exposes FSA operations as MCP tools consumable by any MCP-compatible AI agent.</dd>

<dt id="mdbook">mdBook</dt>
<dd>Rust-based static site generator used as the primary book engine. Source in `DOCS/`, config in `book.toml`, deployed to GitHub Pages by `deploy-book.yml`.</dd>

<dt id="min_quota">MIN_QUOTA</dt>
<dd>Minimum remaining REST quota required before a workflow proceeds. Set per-workflow in `config/workflow-quota-costs.yml`. Typically 500–1500.</dd>

<dt id="mirror-chain">mirror chain</dt>
<dd>Three-org pipeline: Interested-Deving-1896 → OpenOS-Project-OSP (GitHub) → openos-project (GitLab). Managed by mirror-to-osp.yml, mirror-osp-to-gitlab.yml.</dd>

<dt id="node-identity">node identity</dt>
<dd>The position of a fork-sync-all instance in the mirror chain. See `fsa-node-identity.sh`. Determines which operations the instance runs.</dd>

<dt id="ooc">OOC</dt>
<dd>OpenOS-Project-Ecosystem-OOC — the third org in the mirror chain (GitHub). Receives mirrors from OSP.</dd>

<dt id="osp">OSP</dt>
<dd>OpenOS-Project-OSP — the second org in the mirror chain (GitHub). Receives mirrors from Interested-Deving-1896.</dd>

<dt id="osp-bound-repo">OSP-bound repo</dt>
<dd>A repo in Interested-Deving-1896 that is mirrored into OSP and managed by fork-sync-all (README updates, badge injection, CI checks, etc.).</dd>

<dt id="ota">OTA</dt>
<dd>Over-the-air update system. Delivers workflow and config updates from fork-sync-all to consumer repos without requiring manual PRs.</dd>

<dt id="platform-adaptersh">platform-adapter.sh</dt>
<dd>Uniform interface for GitHub, GitLab, Gitea, Forgejo, and Codeberg. Abstracts API differences behind a common shell interface.</dd>

<dt id="pre-flush-prep">pre-flush-prep</dt>
<dd>Pre-flight workflow run before full-chain-flush. Checks quota, validates configs, merges pending PRs, cleans stale branches.</dd>

<dt id="priority-tiers">priority tiers</dt>
<dd>Four-tier workflow priority system: Tier 1 CRITICAL (never cancelled), Tier 2 HIGH (mirror/sync), Tier 3 MEDIUM (READMEs/CI), Tier 4 LOW (translation/maintenance).</dd>

<dt id="queue-manager">queue-manager</dt>
<dd>Workflow that deduplicates queued runs (keeps newest per workflow) and evicts runs queued > 25 min. Runs every 30 min.</dd>

<dt id="quota-reserve">quota-reserve</dt>
<dd>Workflow that cancels low-priority queued runs when quota drops below 1000. Uses per-workflow `min_quota` for cost-aware cancellation.</dd>

<dt id="quota-snapshotsh">quota-snapshot.sh</dt>
<dd>Shared include that captures a REST quota snapshot and writes it to a GitHub Actions variable. Must run after `actions/checkout`.</dd>

<dt id="registered-importsjson">registered-imports.json</dt>
<dd>Registry of upstream repos to keep in sync. Read by `sync-registered-imports.sh` and `sync-registry-sources.yml`.</dd>

<dt id="summarymd">SUMMARY.md</dt>
<dd>mdBook navigation file. Defines the book's table of contents. All book-engine adapters translate this into their native nav format.</dd>

<dt id="sync_token">SYNC_TOKEN</dt>
<dd>GitHub token used for cross-org operations. Shares the same 5000 req/hr REST bucket as `GH_TOKEN` (same user ID 202036334).</dd>

<dt id="template-manifestyml">template-manifest.yml</dt>
<dd>Defines 6 named propagation profiles (full, mirror, infra-core, upstream-sync, standalone, shell-tools) and their file inclusion lists.</dd>

<dt id="time_formatpy">time_format.py</dt>
<dd>Shared Python module providing dual 12h/24h format across all 484 IANA timezones. Includes actor/runner timezone detection and `--test` self-test.</dd>

<dt id="vendor">vendor/</dt>
<dd>Third-party components hosted/deployed by fork-sync-all. Not first-party scripts. Contains infra-dashboard, shell-tools, unified-agnostic-api, book-engine.</dd>

<dt id="workflow-quota-costsyml">workflow-quota-costs.yml</dt>
<dd>Per-workflow REST call cost registry. Drives quota-reserve.sh cancellation, budget.sh pre-flight, and DOCS/quota-costs.md documentation.</dd>

<dt id="world_zones">WORLD_ZONES</dt>
<dd>Dynamic list of all 484 IANA timezone zones in `time_format.py`. Built at import time from `zoneinfo.available_timezones()`, sorted west→east.</dd>

</dl>
