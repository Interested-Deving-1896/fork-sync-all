---
name: fsa-git-workspace
description: Safely acquire, refresh, and inspect a local Git working copy of Fork-Sync-All or another authorized GitHub repository.
---

# FSA Git workspace

Use this skill when repository work would benefit from a local checkout. Do not assume the current AI runtime has shell access or that an FSA-API service is deployed.

## Capability discovery

1. Run `scripts/agent-git-workspace.sh check` when the repository is already checked out and a shell is available.
2. If shell execution is unavailable, use the connected GitHub repository tools and explicitly report that a local clone/fetch was not performed.
3. Do not search for, print, or transmit tokens. Authenticate using the environment's approved GitHub CLI session.

## Safe local workflow

From a trusted checkout of Fork-Sync-All:

```bash
bash scripts/agent-git-workspace.sh check
bash scripts/agent-git-workspace.sh clone Interested-Deving-1896/fork-sync-all /tmp/fork-sync-all
bash scripts/agent-git-workspace.sh status /tmp/fork-sync-all
bash scripts/agent-git-workspace.sh fetch /tmp/fork-sync-all origin
bash scripts/agent-git-workspace.sh status /tmp/fork-sync-all
bash scripts/agent-git-workspace.sh diff /tmp/fork-sync-all
```

The clone command refuses to overwrite an existing path. Fetch updates remote-tracking refs only; it does not check out, merge, pull, reset, or discard local changes. Inspect status before and after fetch. Use a separate worktree or branch for edits and follow repository contribution policy.

## Forking and remote writes

Fork creation is a remote write and requires the explicit command:

```bash
bash scripts/agent-git-workspace.sh fork OWNER/REPO --confirm
```

This requires an authenticated `gh` CLI and may create a repository under the authenticated account. Never invoke it unless the user has requested a fork. This skill does not authorize pushes, merges, branch-protection changes, credential changes, or downstream mirror writes.

## Reporting

Report the actual capability used: local Git runtime, authenticated GitHub CLI, FSA-API, or GitHub API-only. Distinguish a successful API file inspection from a real local clone, fetch, or test run. Never claim a command ran unless its output was observed.
