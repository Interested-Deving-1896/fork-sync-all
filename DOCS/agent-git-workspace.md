# Agent Git workspace access

Fork-Sync-All has multiple AI-agent adapters and a provider-neutral Agent Skills registry. This guide defines a safe baseline for getting a real local Git checkout when an agent runtime supports shell execution.

## Capability boundary

GitHub API/file access is not the same as a local Git working directory. The FSA-API and `fsa` CLI expose repository/control-plane information, but their presence in the source tree does not prove that a live endpoint is deployed or reachable. Agents must report which capability they actually used.

## Helper

Use `scripts/agent-git-workspace.sh` from a trusted checkout:

| Command | Effect | Network / write scope |
|---|---|---|
| `check` | Detect `git`, `gh`, and `gh` auth status | Local checks; no network fetch |
| `clone OWNER/REPO [DIR]` | Create a new local checkout | Reads GitHub; refuses existing target |
| `fetch DIR [REMOTE]` | Update remote-tracking refs | Reads remote; does not alter checkout or worktree |
| `status DIR` | Show root, branch, HEAD, remotes, worktree | Local read-only |
| `diff DIR` | Show tracked unstaged diff | Local read-only |
| `fork OWNER/REPO --confirm` | Create a GitHub fork | Remote write; explicit confirmation and authenticated `gh` required |

The helper intentionally does not implement push, merge, pull, reset, checkout, branch deletion, or mirror synchronization. Fork creation is separately gated because it changes remote account state. Review the helper and your organization's policies before using it.

## Example

```bash
bash scripts/agent-git-workspace.sh check
bash scripts/agent-git-workspace.sh clone Interested-Deving-1896/fork-sync-all /tmp/fork-sync-all
bash scripts/agent-git-workspace.sh status /tmp/fork-sync-all
bash scripts/agent-git-workspace.sh fetch /tmp/fork-sync-all origin
bash scripts/agent-git-workspace.sh status /tmp/fork-sync-all
```

If the runtime has no shell or Git executable, use the available GitHub API connector instead and say clearly that no local clone/fetch occurred.

## Agent Skills integration

The provider-neutral skill lives at `.agents/skills/fsa-git-workspace/SKILL.md`. Follow `DOCS/agent-skills-api.md` and `config/agent-skills.yml` for provider discovery/export. The skill documents a workflow; it does not grant new permissions or execute commands by itself.

## Validation

Run the offline checks:

```bash
bash scripts/tests/test-agent-git-workspace.sh
```

These tests validate input and safety gates without network access. They do not prove GitHub authentication, network access, or successful clone/fetch against a live repository.
