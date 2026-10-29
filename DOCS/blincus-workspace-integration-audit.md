# Blincus workspace integration audit

**Status:** source-level integration audit and proposal; no runtime integration is claimed.
**Scope:** `Interested-Deving-1896/blincus`, upstream `ublue-os/blincus`, and existing Fork-Sync-All Incus / Dev Container tooling.
**Decision:** reuse Blincus as an optional Incus workspace backend/reference behind a provider-neutral workspace contract. Do not make it the orchestrator or silently replace existing backends.

## Executive summary

The two Blincus repositories are **not the same CLI generation** in their current default branches.

- The Interested-Deving-1896 fork's tracked `blincus` script identifies itself as Bashly-generated version `0.4.0`. Its commands include `launch`, `shell`, `template`, `personalize`, and a pass-through to `incus`; `launch` accepts a named template, optional VM size, and optional workspace directory.
- The upstream README currently documents a different, simpler interface: `enter [-i IMAGE]`, `ls`, and `rm [NAME]`, tied to the current project directory.

This is a concrete interface/behavior mismatch, not a proof that every source file differs. Do not sync the upstream README or assume upstream command examples work with the fork. Before changing the fork's implementation or updating from upstream, perform a full source-tree/ancestry diff and decide deliberately whether to preserve the fork's template/VM workflow or port to the newer upstream CLI.

The fork's own source also includes host-integration behavior that makes it unsuitable as an agent sandbox without a separate hardened profile: default home-mount behavior, optional workspace mounts, host UID mapping in profile setup, nesting, GPU/display setup, and an `xhost +` call when `DISPLAY` is set. The source path reviewed includes `incus profile set "$PROFILE" raw.idmap="both $(id -u) 1000"`, `security.nesting=true`, GPU device setup, and `xhost +`. Treat these as significant host-access grants. They must not be inherited implicitly by untrusted agent tasks.

Fork-Sync-All already has relevant building blocks:
- `scripts/docker-to-incus.sh` translates Docker artifacts into Incus-related YAML and its comments describe deleting original Docker artifacts in the same commit. That is a migration tool with broad write effects, not a safe agent-workspace provisioner; do not invoke it as part of workspace startup.
- `.devcontainer/features/incus/` installs the Incus daemon/client with different behavior for privileged and restricted environments.
- `fsa-api/core/adapters/bdfs/import.sh` has an Incus import path and a Dev Container path. Image import is not equivalent to a task-scoped source workspace.
- Existing provider-neutral agent/runtime and safe Git workspace proposals should remain the orchestration and policy owners.

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

- [ ] Full fork/upstream tree and ancestry diff plus license/provenance review recorded.
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

- The fork executable reports version `0.4.0` and exposes `launch/shell/template/personalize`; upstream README documents `enter/ls/rm`. This mismatch must be resolved before any README synchronization or adapter implementation.
- Fork source includes a host-home mount, optional workspace mount, `raw.idmap`, `security.nesting=true`, GPU/display setup, and `xhost +`. Do not run this code on a host or enable these features for agent jobs without deliberate review and a separate profile.
- The fork README still contains pending description/architecture/usage placeholders. Improve its human-owned Install/Usage/Configuration sections only through a deliberate, reviewed fork-specific change; do not overwrite the README wholesale with generated text.
- Existing `docker-to-incus.sh` has explicit broad conversion/deletion behavior and requires a token. Do not use it as an adapter or trigger it to test this proposal.
- This is a documentation-only integration proposal. No Incus daemon, containers, profiles, sockets, host settings, credentials, workflows, or downstream mirrors were touched. No live Incus runtime test was possible from this audit.
