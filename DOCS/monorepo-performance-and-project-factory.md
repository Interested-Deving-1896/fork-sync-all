# Monorepo Performance and Project Factory Architecture

## Context

This design connects two topics:

- [penguins-eggs issue #79: Git FSMonitor for monorepo performance](https://github.com/pieroproietti/penguins-eggs/issues/79)
- [GitHub Engineering: Improve Git monorepo performance with a file system monitor](https://github.blog/engineering/infrastructure/improve-git-monorepo-performance-with-a-file-system-monitor/)

Issue #79 references Git's FSMonitor work and is closed. The linked GitHub Engineering article explains how FSMonitor reduces repeated worktree scans for commands such as `git status`, `git diff`, and `git add`. It reports large improvements on large worktrees, while noting that the first daemon/index synchronization may still be slow.

## Architectural distinction

Fork-Sync-All should support both:

1. **Multi-repository orchestration** — the project factory creates, configures, links, and synchronizes independent repositories using a manifest and platform adapters.
2. **Optional monorepo/workspace mode** — selected components are composed into one repository with preserved provenance/history where possible, workspace metadata, build/test orchestration, and selective checkout.

Do not force all ecosystem projects into a monorepo. The registry should express the repository topology as a project profile.

## Project factory manifest extension

Conceptual fields:

```yaml
schema_version: "1"
project:
  name: example
  topology: multi-repo # multi-repo | monorepo | hybrid
  vcs:
    provider: git # provider-neutral core
  workspace:
    sparse_checkout: optional
    fsmonitor: auto
    untracked_cache: auto
  components:
    - name: core
      source: template://core
      path: components/core
      independent_repository: false
```

The actual schema should use the existing template-registry conventions and validation before this example is adopted.

## FSMonitor policy

FSMonitor is a developer-workstation optimization, not a universal CI setting.

- Detect Git version and platform capabilities before enabling.
- Prefer Git's built-in `core.fsmonitor=true` where supported (Git 2.37+ article describes built-in daemon support on macOS and Windows at publication time; verify current support matrix before rollout).
- Consider `core.untrackedCache=true` together with FSMonitor, after capability checks.
- On Linux or environments where built-in FSMonitor is unsupported or unsuitable, allow a compatible external monitor such as Watchman through Git's supported protocol, but do not require it.
- Make the setting opt-in/auto-detected, reversible, and documented.
- Do not write global Git configuration by default. Use repository-local config or an explicit developer bootstrap option.
- CI runners are ephemeral; benchmark before enabling there.
- Provide a safe fallback: disable monitor and run ordinary Git operations if startup, synchronization, or monitor health fails.

Potential developer command (documentation example only):

```bash
git config --local core.fsmonitor true
git config --local core.untrackedCache true
git fsmonitor--daemon status
```

The implementation must verify that `git fsmonitor--daemon` is supported before setting the option and must not leave a broken configuration behind.

## Additional monorepo optimizations

FSMonitor is one layer. The project factory should consider:
- sparse checkout / sparse index for large workspaces when component boundaries permit
- avoiding generated build artifacts inside the source worktree; use external build/output directories
- `.gitignore` hygiene and untracked-cache compatibility
- partial clone / blob filtering where remote and CI policies support it
- workspace-aware task execution (only build/test affected components)
- independent component ownership, dependency graph, versioning, and release rules
- repository splitting/export tooling for projects that later need to become independent

## Project creation lifecycle

1. Resolve template-registry manifest and validate topology.
2. Create repositories or initialize the monorepo/hybrid workspace.
3. Materialize components with provenance and ownership metadata.
4. Configure platform-neutral remote(s) and Git provider adapters.
5. Apply opt-in local performance profile (FSMonitor/sparse checkout) only when supported.
6. Generate workspace and CI tasks.
7. Run validation, test, and creation smoke checks.
8. Produce an audit report and links; no automatic merge or publication to protected branches.

## How AI Discussion Bridge fits

The AI Discussion Bridge can be registered as an optional project capability:
- multi-repo mode: install its workflow and adapter configuration in the designated governance/docs repository;
- monorepo mode: place the bridge under a component boundary, e.g. `tools/ai-discussion-bridge/`, while keeping provider and Git-platform adapters independent;
- hybrid mode: publish canonical Markdown to a shared discussion repository and cross-link to component repositories.

Imported Gemini conversations about penguins-eggs (including issue #79 research) can become Markdown provenance artifacts and then be published as GitHub Discussions, GitLab threads, or repository files. The conversion/import operation is distinct from changing or closing the upstream issue.

## Validation / acceptance criteria

- Schema accepts multi-repo, monorepo, and hybrid topology.
- Project creation tests verify repository creation and component paths without mutating protected default branches.
- FSMonitor profile has unit tests for version/platform detection and configuration rollback.
- CI benchmark compares baseline and optimized `git status` / `git diff` on representative fixture repositories; avoid hard-coded performance promises.
- Sparse checkout tests prove generated files and selected components are present.
- Bridge import fixtures validate title, role order, formatting, attribution, partial extraction, duplicate detection, and unsafe URLs.
- End-to-end test creates a preview artifact and publishes only in an explicitly enabled integration environment.
