# Blincus workspace integration audit

**Status:** source-level integration audit and proposal; no runtime integration is claimed.
**Scope:** `Interested-Deving-1896/blincus`, upstream `ublue-os/blincus`, and existing Fork-Sync-All Incus / Dev Container tooling.
**Decision:** reuse Blincus as an optional Incus workspace backend/reference behind a provider-neutral workspace contract. Do not make it the orchestrator or silently replace existing backends.

## Executive summary

The two Blincus repositories are **not the same CLI generation** in their current default branches.

- The Interested-Deving-1896 fork's tracked `blincus` script identifies itself as Bashly-generated version `0.4.0`. Its commands include `launch`, `shell`, `template`, `personalize`, and a pass-through to `incus`; `launch` accepts a named template, optional VM size, and optional workspace directory.
- The upstream README currently documents a different, simpler interface: `enter [-i IMAGE]`, `ls`, and `rm [NAME]`, tied to the current project directory.
- **Full default-branch tree and ancestry comparison is now recorded below.** The upstream `main` points to `f6abf391daa29f4377ef8a29e67216341b313eaf` (2026-07-07, “blincus v2: single-purpose rewrite (#60)”); the fork `main` points to `492e2d43bc9555a41794f4d1aea2a39dc26981ad` (2026-10-16, README-only update). Their merge base is `a5d6c23df141c53642b75a2830299e458ceefe44`. GitHub compare reports the fork branch as 17 commits behind and 1 commit ahead of the upstream target, with the single ahead commit being the fork's README update.
- The upstream rewrite is a deliberate architectural change, not a routine patch-level sync. A blind merge or branch-ref overwrite would remove substantial fork-only features and documentation. Do not run the registered-import workflow with force-style branch refspecs against this repository as a substitute for reviewed migration.

This mismatch is a concrete interface/behavior difference. Do not sync the upstream README or assume upstream command examples work with the fork. The next decision is whether the fork should adopt upstream Blincus v2 as its baseline and port only explicitly selected fork-specific functionality, or remain a distinct template/VM-oriented variant. That decision should precede a source-changing sync PR.

The fork's own source also includes host-integration behavior that makes it unsuitable as an agent sandbox without a separate hardened profile: default home-mount behavior, optional workspace mounts, host UID mapping in profile setup, nesting, GPU/display setup, and an `xhost +` call when `DISPLAY` is set. The source path reviewed includes `incus profile set "$PROFILE" raw.idmap="both $(id -u) 1000"`, `security.nesting=true`, GPU device setup, and `xhost +`. Treat these as significant host-access grants. They must not be inherited implicitly by untrusted agent tasks.

Fork-Sync-All already has relevant building blocks:
- `scripts/docker-to-incus.sh` translates Docker artifacts into Incus-related YAML and its comments describe deleting original Docker artifacts in the same commit. That is a migration tool with broad write effects, not a safe agent-workspace provisioner; do not invoke it as part of workspace startup.
- `.devcontainer/features/incus/` installs the Incus daemon/client with different behavior for privileged and restricted environments.
- `fsa-api/core/adapters/bdfs/import.sh` has an Incus import path and a Dev Container path. Image import is not equivalent to a task-scoped source workspace.
- Existing provider-neutral agent/runtime and safe Git workspace proposals should remain the orchestration and policy owners.

## Verified upstream/fork comparison

Comparison performed against the default branch commit and tree objects exposed by GitHub on 2026-10-29:

| Item | Upstream `ublue-os/blincus` | Fork `Interested-Deving-1896/blincus` |
|---|---|---|
| `main` SHA | `f6abf391daa29f4377ef8a29e67216341b313eaf` | `492e2d43bc9555a41794f4d1aea2a39dc26981ad` |
| Latest main commit | 2026-07-07, Blincus v2 rewrite | 2026-10-16, README AI-owned-section update |
| Tree SHA | `108bdef290c2299368a7b04b6cea19fadeaa22e8` | `0ad66d413eac7435da8c0bb230fdc872d0e18454` |
| Recursive tree entries | 15 | 151 |
| GitHub compare status | `diverged` | `diverged` |
| Shared merge base | `a5d6c23df141c53642b75a2830299e458ceefe44` | same |
| Commit counts from fork main to upstream target | upstream target is 1 commit ahead of merge base | fork main is 17 commits ahead of merge base, including README maintenance |

The upstream v2 rewrite replaces the roughly 1,947-line Bashly-generated CLI with a hand-written shell script of roughly 300 lines, centered on `enter`, `ls`, and `rm`. The upstream commit message describes deleting the Bashly source/toolchain, template and profile/cloud-init libraries, VM mode, Astro documentation site, Nix flake, Dockerfile, and Dev Container configuration. The recursive trees confirm that upstream now has a much smaller layout than the fork. This is not merely a README or generated-file change.

The compare endpoint reports many fork paths removed by the upstream rewrite, including:
- `.devcontainer/devcontainer.json`, `Dockerfile`, `flake.nix`, `flake.lock`, and `.github/workflows/flakehub-publish-tagged.yml`;
- `cloud-init/`, `profiles/`, `scripts/`, `src/`, `templates/`, and `test/`;
- the `site/` Astro docs site and its package lock;
- legacy command implementation files and configuration/template commands.

The upstream adds `docs/superpowers/plans/2026-07-07-blincus-v2.md` and `docs/superpowers/specs/2026-07-07-blincus-simplification-design.md`, and materially rewrites `blincus`, `install`, `uninstall`, `Justfile`, `completions/blincus`, and `README.md`.

**Important comparison limit:** the GitHub compare is based on a common ancestor and reports the delta between the two tips. It proves substantial divergence and the direction/content of the upstream rewrite, but it does not establish that every fork-only file should be deleted or that a direct merge is semantically safe. A path-by-path disposition and tests are still required before a source-changing migration.

### Recommended synchronization policy

1. **Do not force-sync or overwrite `Interested-Deving-1896/blincus` from the registered-import workflow.** Its `+refs/heads/*:refs/heads/*` push refspec can replace same-named target branch heads. The upstream/fork main divergence is now known to be a major rewrite.
2. Preserve the current fork main and its history as the review baseline.
3. Create a dedicated migration branch from the current fork main and bring upstream v2 changes into that branch for review. Do not push directly to `main`.
4. Decide each fork-only capability separately: retain, port onto v2, replace with an adapter, or intentionally retire. In particular, do not silently drop VM/template functionality, Nix/devcontainer packaging, docs, or tests.
5. Keep fork-owned README sections and automation-owned README sections distinct; do not wholesale replace the README.
6. Run shell lint and upstream smoke tests where available, plus fork-specific regression tests for any retained features. Clearly separate static review from tests that require a live Incus host.
7. Open a PR with the migration matrix, test evidence, and user-visible breaking changes. Do not merge automatically.

## Responsibility boundaries

| Layer | Owns | Must not own |
|---|---|---|
| Fork-Sync-All control plane | Task policy, authorization, task/PR lifecycle, evidence and audit trail, quotas, reporting | Incus host privileges or implicit host access |
| Workspace contract | Stable lifecycle requests/results and capability declarations | Backend-specific implementation details |
| Incus/Blincus adapter | Provision, inspect, exec, stop, remove and recover an Incus workspace using least privilege | Provider selection, GitHub PR policy, merge decisions |
| Agent adapter (OpenCode first) | Invoke a configured agent inside an approved workspace and return structured outcomes | Granting itself extra host/Incus permissions |
| Human interactive profile | Optional GUI, audio, GPU and developer conveniences | Untrusted PR execution defaults |
| Safe Git workspace helper | Clone/fetch/status/diff and explicitly authorized repository actions | Treating workspace creation as permission to push or merge |

A workspace is a resource boundary; an agent session is a task/process boundary. They must have separate identifiers and lifecycles. Reusing a workspace must not imply reusing credentials, task authorization, or agent session state.

## Proposed provider-neutral contract

These are proposed API operations, not existing Blincus CLI commands:

- `create_workspace(request) -> workspace_id, capabilities, state`
- `inspect_workspace(workspace_id) -> state, health, mounts, resource usage`
- `exec_workspace(workspace_id, command, env_allowlist, timeout) -> exit status, bounded output`
- `enter_workspace(workspace_id) -> interactive handle` (human/interactive capability only)
- `stop_workspace(workspace_id, reason)`
- `preserve_workspace(workspace_id, manifest)` (capture recovery metadata and identify uncommitted work)
- `destroy_workspace(workspace_id, confirmation_or_policy)`
- `recover_workspace(workspace_id)`

Each backend should report explicit capabilities such as `interactive_shell`, `gui_forwarding`, `gpu`, `snapshot`, `persistent_storage`, `network_policy`, `resource_limits`, and `isolated_vm`. Unsupported capabilities must be reported as unsupported, not silently emulated.

A request should include a generated task/workspace ID, repository URL and immutable target ref, workspace path, image reference, lifecycle policy, resource limits, network policy, permitted environment-variable names (not secret values), persistence/recovery policy, and a policy profile. Results should include backend identity/version, image digest when available, timestamps, exit/status evidence, and cleanup/recovery outcome.

## Security profiles

### 1. Interactive developer profile

May opt into GUI/audio/GPU forwarding after a human request. Display sockets, host UID mapping, host home mounts, nesting, and host integration must be visible in the profile and documented as host-access grants. Avoid broad X11 access; replace `xhost +` with a narrowly scoped access grant where possible. Do not silently alter the user's Incus profiles or subordinate-ID configuration.

### 2. Agent sandbox profile (default for automation)

- No X11, Wayland, audio, desktop session, or GPU sockets by default.
- No host UID mapping / `raw.idmap` by default.
- No host-home mount, arbitrary home subdirectory mounts, or nesting by default.
- Never expose the Incus admin/control socket or privileged daemon access to agent code.
- Mount only the selected checkout/worktree; validate canonical paths and reject unexpected parent/root paths.
- Do not pass the host environment wholesale. Use an explicit variable allowlist and short-lived, narrowly scoped credentials only when necessary.
- Set resource and timeout limits where the selected backend supports them; report when it does not.
- Apply an explicit network policy; do not claim network isolation unless tested.
- Keep PR code and agent subprocesses untrusted. A container is not automatically equivalent to a VM or a complete security boundary.
- On cancellation/failure, stop processes safely and preserve a recovery manifest before cleanup. Never destroy a workspace containing uncommitted work without an explicit policy decision and a recoverability check.

## Backend integration sequence

1. **Resolve fork/upstream strategy:** compare full source trees and ancestry, scripts, tests, install behavior, templates, profiles, and socket handling. Record fork-only behavior and decide whether the fork tracks upstream or remains a distinct template/VM-oriented variant.
2. **Specify the contract and threat model:** define request/result schemas, state machine, capabilities, timeouts, errors, idempotency, and cleanup ownership.
3. **Implement a read-only capability probe first:** detect Incus availability/version and profile/configuration prerequisites without initializing Incus, creating resources, editing host configuration, or changing profiles.
4. **Add an opt-in Incus workspace adapter:** explicit create/inspect/exec/stop/remove operations; stable task labels; path-safe mount validation; bounded logs; no implicit GUI, host-home mount, nesting, or UID mapping.
5. **Connect the existing safe Git workspace helper:** checkout a requested immutable ref into a dedicated worktree, preserve branch/dirty-state evidence, and keep GitHub write actions separately gated.
6. **Connect OpenCode through the agent-neutral runtime contract:** run only after workspace policy is evaluated. Keep the agent adapter independent from Incus so another backend can be tested.
7. **Add recovery/lifecycle reporting:** distinguish task completed, task failed, task cancelled, workspace stopped, workspace preserved, and workspace destroyed. An empty or missing observation is unknown, not healthy.
8. **Validate offline first:** fake/mock Incus CLI tests for argument construction, path validation, state transitions, timeouts, partial failures, repeated calls, cancellation, and recovery. Then run isolated integration tests only on an explicitly provisioned disposable host.

## Acceptance gates

- [x] Default-branch ancestry and recursive tree comparison recorded, including shared merge base and diverged status.
- [ ] Path-by-path disposition and license/provenance review recorded before source migration.
- [ ] CLI-generation mismatch is resolved/documented; README instructions match the fork's actual executable.
- [ ] Contract schema and state machine reviewed.
- [ ] Read-only capability probe does not mutate the host.
- [ ] Agent profile has no GUI socket forwarding, host UID map, host-home mount, nesting, or Incus control socket.
- [ ] Workspace path and repository ref are validated; commands are passed as argument arrays rather than interpolated shell strings.
- [ ] Create/reuse is idempotent and bound to a workspace/task identity, not merely the basename of the current directory.
- [ ] Failure injection covers create timeout, daemon unavailable, mount failure, agent exit, cancellation, and cleanup failure.
- [ ] Dirty/untracked files are reported and recoverable before destroy.
- [ ] Capability reporting distinguishes unavailable/unknown from healthy.
- [ ] Offline tests and lint pass; live Incus integration tests are separately identified.
- [ ] No PR is auto-merged; no workflows are manually dispatched/rerun without separate authorization.
- [ ] No downstream mirror is written directly; the normal reviewable mirror chain remains in charge.

## Current findings and limitations

- The upstream/fork tree and ancestry comparison is complete at the GitHub metadata/tree level; the path-by-path disposition is not yet complete.
- The fork executable reports version `0.4.0` and exposes `launch/shell/template/personalize`; upstream v2 documents `enter/ls/rm`. The upstream main branch is 1 commit ahead of the shared base, while the fork main is 17 commits ahead of that base; the fork has one ahead commit relative to the upstream target, a README maintenance commit.
- Fork source includes a host-home mount, optional workspace mount, `raw.idmap`, `security.nesting=true`, GPU/display setup, and `xhost +`. Do not run this code on a host or enable these features for agent jobs without deliberate review and a separate profile.
- The fork README still contains pending description/architecture/usage placeholders. Improve its human-owned Install/Usage/Configuration sections only through a deliberate, reviewed fork-specific change; do not overwrite the README wholesale with generated text.
- Existing `docker-to-incus.sh` has explicit broad conversion/deletion behavior and requires a token. Do not use it as an adapter or trigger it to test this proposal.
- This remains a documentation and static-metadata audit. No Incus daemon, containers, profiles, sockets, host settings, credentials, workflows, or downstream mirrors were touched. No live Incus runtime test was performed.
