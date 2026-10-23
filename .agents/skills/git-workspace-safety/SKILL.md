---
name: git-workspace-safety
description: Safely acquire and inspect a local Git checkout without implicit pushes, merges, resets, or branch changes.
license: MIT
compatibility: Requires Python 3 and Git for local workspace commands; API-only environments should report local Git unavailable.
metadata:
  category: repository-operations
  provider-neutral: "true"
---

# Safe Git workspace operations

Use this skill when an agent needs a reproducible local checkout of a repository.

## Capability discovery

1. Check whether Python 3 and Git are available.
2. If Git is unavailable, state that local clone/fetch/status operations are unavailable; use an authorized provider API for read-only inspection instead.
3. Do not infer that an API token, `gh`, or a local shell is configured just because a provider connector is available.

## Safe local helper

From the repository root:

- Validate coordinates: `python3 scripts/git-workspace.py validate --coordinates owner/repo`
- Validate a remote: `python3 scripts/git-workspace.py validate --url https://github.com/owner/repo.git`
- Clone to a new or empty directory: `python3 scripts/git-workspace.py clone --url https://github.com/owner/repo.git --destination ../repo-checkout`
- Inspect branch, HEAD, origin, and dirty state: `python3 scripts/git-workspace.py status ../repo-checkout`
- Fetch origin refs without changing the working tree: `python3 scripts/git-workspace.py fetch ../repo-checkout`
- Inspect staged and unstaged diff summaries: `python3 scripts/git-workspace.py diff ../repo-checkout`

The helper rejects credential-bearing URLs, unsupported URL schemes, and non-empty clone destinations. Fetch does not merge, rebase, reset, checkout, or discard local changes.

## Explicit authorization gates

The helper intentionally does not implement push, merge, reset, checkout, fork creation, or branch mutation. Those actions require a separate, explicit authorization and a separately reviewed workflow. Never put credentials in URLs or command-line arguments.

## Offline validation

Run the validation tests without accessing a remote:

```bash
python3 -m pytest -q tests/test_git_workspace.py
```

Treat this as a first iteration: verify the helper and the actual local runtime before claiming a workspace is ready. The helper does not deploy the FSA API, create forks, or configure credentials.
