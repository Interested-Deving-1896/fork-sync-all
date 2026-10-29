# Blincus workspace integration audit

**Status:** proposal and source-level integration audit; no runtime integration is claimed.
**Scope:** `Interested-Deving-1896/blincus`, upstream `ublue-os/blincus`, and the existing Fork-Sync-All Incus / Dev Container tooling.
**Decision:** reuse Blincus as an optional Incus workspace backend/reference behind a provider-neutral workspace contract. Do not make it the orchestrator or silently replace existing backends.

## Executive summary

Blincus upstream is a human-oriented, project-directory-bound Incus container launcher. Its documented `enter`, `ls`, and `rm` commands create/reuse a container for the current directory, mount that directory, forward GUI/audio/GPU access, and provide a login shell. This is useful for interactive development, but the GUI and host-identity features are not safe defaults for unattended or untrusted agent tasks.

The Interested-Deving-1896 fork README is currently in generated/template state and does not describe implementation-specific divergence. A direct code diff against upstream could not be established from the available repository comparison endpoint, so this audit does **not** claim the fork is identical or divergent. Before changing the fork itself, compare its source tree and commit ancestry with `ublue-os/blincus`.

Fork-Sync-All already has relevant building blocks:
- `scripts/docker-to-incus.sh` translates Docker artifacts into Incus-related YAML and its comments describe deleting the original Docker artifacts in the same commit. That is a migration tool with broad write effects, not a safe agent-workspace provisioner; do not invoke it as part of workspace startup.
- `.devcontainer/features/incus/` installs the Incus daemon/client with different behavior for privileged and restricted environments.
- `fsa-api/core/adapters/bdfs/import.sh` has an Incus import path and a Dev Container path. Image import is not equivalent to a task-scoped source workspace.
- Existing provider-neutral agent/runtime and safe Git workspace proposals should remain the orchestration and policy owners.

## Responsibility boundaries

| Layer | Owns | Must not own |
|---|---|---|
| Fork-Sync-All control plane | Task policy, authorization, task/PR lifecycle, evidence and audit trail, quotas, reporting | Incus host privileges or implicit host access |
| Workspace contract | Stable lifecycle requests/results and capability declarations | Backend-specific implementation details |
| Incus/Blincus adapter | Provision, inspect, enter/exec, stop, remove and recover an Incus workspace using least privilege | Provider selection, GitHub PR policy, merge decisions |
| Agent adapter (OpenCode first) | Invoke a configured agent inside an approved workspace and return structured outcomes | Granting itself extra host/Incus permissions |
| Human interactive profile | Optional GUI, audio, GPU and developer conveniences | Untrusted PR execution defaults |
| Safe Git workspace helper | Clone/fetch/status/diff and explicitly authorized repository actions | Treating workspace creation as permission to push or merge |

A workspace is a resource boundary; an agent session is a task/process boundary. They must have separate identifiers and lifecycles. A reused workspace must not imply reuse of credentials, task authorization, or agent session state.

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

May opt into GUI/audio/GPU forwarding after a human request. Display sockets, host UID mapping, and host integration must be visible in the profile and documented as host-access grants. Avoid broad X11 access. Do not silently alter the user's Incus profiles or subordinate-ID configuration.

### 2. Agent sandbox profile (default for automation)

- No X11, Wayland, audio, desktop session, or GPU sockets by default.
- No host UID mapping / `raw.idmap` by default.
- Never expose the Incus admin/control socket or privileged daemon access to agent code.
- Mount only the selected checkout/worktree; do not mount the host home directory or arbitrary parent directories.
- Do not pass the host environment wholesale. Use an explicit variable allowlist and short-lived, narrowly scoped credentials only when necessary.
- Set resource and timeout limits where the selected backend supports them; report when it does not.
- Apply an explicit network policy; do not claim network isolation unless tested.
- Keep PR code and agent subprocesses untrusted. A container is not automatically equivalent to a VM or a complete security boundary.
- On cancellation/failure, stop processes safely and preserve a recovery manifest before cleanup. Never destroy a workspace containing uncommitted work without an explicit policy decision and a recoverability check.

## Backend integration sequence

1. **Audit fork and upstream source:** compare trees, ancestry, executable scripts, tests, install behavior, and profile/socket handling. Record any fork-only behavior before proposing upstream synchronization.
2. **Specify the contract and threat model:** define request/result schemas, state machine, capabilities, timeouts, errors, idempotency, and ownership of cleanup.
3. **Implement a read-only capability probe first:** detect Incus availability/version and profile/configuration prerequisites without initializing Incus, creating resources, editing host configuration, or changing profiles.
4. **Add an opt-in Incus workspace adapter:** explicit create/inspect/exec/stop/remove operations; stable task labels; path-safe mount validation; bounded logs; no implicit GUI or UID mapping.
5. **Connect the existing safe Git workspace helper:** checkout a requested immutable ref into a dedicated worktree, preserve branch/dirty-state evidence, and keep GitHub write actions separately gated.
6. **Connect OpenCode through the agent-neutral runtime contract:** run only after workspace policy is evaluated. Keep the agent adapter independent from Incus so another backend can be tested.
7. **Add recovery/lifecycle reporting:** distinguish task completed, task failed, task cancelled, workspace stopped, workspace preserved, and workspace destroyed. An empty or missing observation is unknown, not healthy.
8. **Validate offline first:** fake/mock Incus CLI tests for argument construction, path validation, state transitions, timeouts, partial failures, repeated calls, cancellation, and recovery. Then run isolated integration tests only on an explicitly provisioned disposable host.

## Acceptance gates

- [ ] Fork/upstream source diff and license/provenance review recorded.
- [ ] Contract schema and state machine reviewed.
- [ ] Read-only capability probe does not mutate the host.
- [ ] Agent profile has no GUI socket forwarding, host UID map, host home mount, or Incus control socket.
- [ ] Workspace path and repository ref are validated; commands are passed as argument arrays rather than interpolated shell strings.
- [ ] Create/reuse is idempotent and bound to a workspace/task identity, not merely the basename of the current directory.
- [ ] Failure injection covers create timeout, daemon unavailable, mount failure, agent exit, cancellation, and cleanup failure.
- [ ] Dirty/untracked files are reported and recoverable before destroy.
- [ ] Capability reporting distinguishes unavailable/unknown from healthy.
- [ ] Offline tests and lint pass; live Incus integration tests are separately identified.
- [ ] No PR is auto-merged; no workflows are manually dispatched/rerun without separate authorization.
- [ ] No downstream mirror is written directly; the normal reviewable mirror chain remains in charge.

## Current findings and limitations

- The upstream README documents `blincus enter [-i IMAGE]`, `blincus ls`, and `blincus rm [NAME]`; it documents forwarding display/audio/GPU, a shared Incus profile, a systemd user service, and host UID mapping. Those features are reasons to separate interactive and agent profiles.
- The fork README still contains pending description/architecture/usage placeholders. Improve its human-owned Install/Usage/Configuration sections only through a deliberate, reviewed fork-specific change; do not overwrite the README wholesale with generated text.
- Existing `docker-to-incus.sh` has an explicit broad conversion/deletion behavior and requires a token. Do not use it as an adapter or trigger it to test this proposal.
- This is a documentation-only integration proposal. No Incus daemon, containers, profiles, sockets, host settings, credentials, workflows, or downstream mirrors were touched. No live Incus runtime test was possible from this audit.
