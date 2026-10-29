# Ona deprecation and provider-neutral migration audit

**Status:** Initial inventory; implementation must be reconciled with existing AI-agent-neutral PRs before retiring active components.

## Objective

Remove Ona as an active or required development-environment / AI-agent integration from Fork-Sync-All. Reuse the existing provider-neutral agent skills, Git workspace, platform-adapter, template registry, onboarding, and agent-integration work. Do not create a competing project factory or require any particular AI provider or hosted environment.

This is a migration, not a blanket deletion of the string `Ona`: historical release notes, attribution, and a clearly labelled migration/compatibility note may retain references.

## Initial search inventory

The repository-wide GitHub code search returned matches in at least these paths. This is an initial source inventory, not a guarantee that every generated file or historical commit has been reviewed.

### Active Ona-specific operations and configuration

- `config/ona-projects.yml` — vendor-specific project registry and project IDs.
- `scripts/ona-projects.sh` — Ona API project creation/update and ONA_TOKEN handling.
- `scripts/ona-mcp-server.py` — Ona API-backed MCP tools.
- `scripts/agent-budget-ona.py` — provider-specific usage/billing adapter.
- `.github/workflows/sync-ona-projects.yml` — scheduled/dispatch project sync.
- `.ona/config.yaml` and `.ona/skills/*` — Ona environment and skill-specific instructions.
- `.devcontainer/devcontainer.json` — legacy ONA_TOKEN / ONA_API / ONA_MCP_URL environment forwarding.
- `config/agent-budget.yml`, `config/agent-cost-profiles.yml`, `config/workflow-quota-costs.yml`, `scripts/validate-agent-budget-config.py`, and `scripts/sync-agent-prices.py` — budget, pricing, and validation references that need dependency-aware review.
- `scripts/devcontainer-validate.py` — currently validates Ona configuration and automation templates.
- `scripts/pin-version.sh`, `scripts/ota-discover.sh`, `scripts/ota-deliver.sh` — Ona co-author attribution in generated commits; replace only if it is generated metadata rather than genuine historical attribution.

### Documentation, generated references, and onboarding

- `AGENTS.md` — Ona-specific billing guidance and environment limitations; this file is consumed by downstream projects, so avoid broad or unreviewed edits.
- `DOCS/contributing.md` — “New Ona project” instructions.
- `DOCS/ai-agent-costs.md` and `DOCS/agent-budget-governor.md` — provider-specific billing details and API references.
- `DOCS/agent-skills-api.md` and `fsa-api/README.md` — legacy Ona skill/runtime compatibility.
- `DOCS/fsa-api-deployment.md` — Ona environment deployment path.
- `DOCS/architecture.md`, `DOCS/generated/glossary.md`, `DOCS/generated/source-tree.md`, `DOCS/generated/workflow-reference.md`, `DOCS/workflow-triggers.md`, `DOCS/workflow-triggers.txt`, `docs/workflow-triggers.md`, and `docs/workflow-triggers.txt` — architecture, generated indexes, and workflow schedules.
- `config/workflow-quota-costs.yml` — workflow description and Ona API quota accounting.
- `README.md` and `DOCS/codex-cloud-migration.md` — transition messaging. Keep time-bound migration notes only while useful and accurately dated.
- `CHANGELOG.md` and `readme-subsystem/CHANGELOG.md` — historical entries should remain historical rather than be rewritten to imply the old integration never existed.
- `.reuse/dep5` — attribution/license metadata for `.ona/*`; update consistently if files are retired.
- Additional code-search hits include `scripts/bootstrap-org.sh`, `scripts/generate-book-pages.py`, `scripts/validate-workflows.sh`, `scripts/list-ci-targets.py`, `scripts/includes/fsa-node-identity.sh`, `config/agent-skills.yml`, `config/defaults.yaml`, `config/ai-agent-badges.json`, `fsa-api/config/fsa-routes.yml`, and `fsa-api/uaa/README.md`. Each match must be classified in context before editing.

## Existing provider-neutral alternatives to reconcile first

- `scripts/includes/platform-adapter.sh`: common Git hosting operations across supported forges.
- `scripts/onboard-repo.sh`, `scripts/import-repo.sh`, `config/onboarding.yml`, `config/template-manifest.yml`, `config/template-consumers.yml`, and `scripts/sync-template.sh`: existing repository onboarding and template machinery.
- `config/agent-skills.yml` and `DOCS/agent-skills-api.md`: canonical skill package and provider-neutral projection.
- `config/ai-agent-badges.json` and `scripts/agent-badge-registry.py`: provider registry and README badge projection.
- Open proposals include PR #717 and PR #718 for provider-neutral agent integration, PR #699 and PR #834 for safe provider-neutral Git workspace operations, and PR #663 for isolated Codex setup guidance. Verify current PR state and changed files before reusing their work; do not assume a proposal is merged or operational.

## Required migration sequence

1. Inventory all matches and classify them as: active dependency, provider-specific adapter, portable capability, environment-only glue, generated output, history/attribution, or migration guidance.
2. Reconcile every proposed replacement against existing PRs and merged implementations.
3. Move portable project operations behind shared lifecycle interfaces and use the existing template registry/onboarding path. Do not create a second canonical project registry.
4. Keep MCP as an optional interoperability adapter over provider-neutral operations, not as the business-logic layer and not tied to Ona.
5. Preserve provider-specific cost telemetry only behind optional adapters; generic budget admission must work without Ona fields, secrets, API endpoints, or assumptions about billing units.
6. Migrate reusable skills to the canonical provider-neutral skill layout and remove environment-specific instructions where equivalent portable workflows exist.
7. Update source documentation and validation scripts, then regenerate derived docs using their established generators.
8. Retire Ona-only workflow/config/scripts only after a replacement exists or the capability is explicitly declared obsolete. Remove stale secret forwarding and workflow triggers only after all consumers are accounted for.
9. Validate YAML/JSON, shell syntax, Python syntax, skill registry, docs generation, workflow references, and search results. Do not dispatch workflows or merge PRs as part of this change.

## Safety and acceptance criteria

- No mandatory AI provider or hosted development environment.
- Project creation uses the existing template registry, onboarding, and platform adapter.
- Existing mirror-write protections, human-owned README sections, approval gates, secret handling, and least-privilege boundaries remain intact.
- No active workflow points at retired Ona-only scripts or configuration.
- Generic budget validation does not require Ona-specific provider data.
- Reusable skills are discoverable in the canonical provider-neutral layout.
- Historical attribution and changelog facts remain accurate.
- Final audit reports remaining Ona references and explains why each intentional reference remains.
