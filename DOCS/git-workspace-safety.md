# Safe provider-neutral Git workspace

This first iteration adds `scripts/git-workspace.py` and the `git-workspace-safety` Agent Skill for agents that need a local Git checkout. It does not require the FSA API to be deployed and does not assume every agent has a local shell.

## Capability contract

- **Local Git available:** the helper can validate repository coordinates/URLs and perform clone, fetch, status, and diff-summary operations.
- **Git unavailable:** report local operations as unavailable; use provider APIs only for the read-only operations they support.
- **Credentials:** remote URLs containing passwords or embedded credentials are rejected. Use an already-configured SSH agent or credential helper rather than putting secrets in a URL.
- **Clone:** destination must be new or an empty directory.
- **Fetch:** fetches `origin` without merging/rebasing or changing the working tree.
- **Status/diff:** read-only; report local modifications instead of discarding them. Status reports whether `origin` is configured, not its raw URL, so credentials embedded in an existing remote are not echoed. Git command error details also redact HTTP(S)/SSH URL user-info before reporting failures.

## Commands

```bash
python3 scripts/git-workspace.py validate --coordinates Interested-Deving-1896/fork-sync-all
python3 scripts/git-workspace.py validate --url https://github.com/Interested-Deving-1896/fork-sync-all.git
python3 scripts/git-workspace.py clone --url https://github.com/Interested-Deving-1896/fork-sync-all.git --destination ../fork-sync-all-checkout
python3 scripts/git-workspace.py status ../fork-sync-all-checkout
python3 scripts/git-workspace.py fetch ../fork-sync-all-checkout
python3 scripts/git-workspace.py diff ../fork-sync-all-checkout
python3 -m pytest -q tests/test_git_workspace.py
```

## Authorization boundary

The helper does not create forks, push, merge, reset, checkout, create branches, or modify repository permissions. Those operations require explicit authorization and a separately reviewed process. The clone command accesses the supplied remote and therefore may require network access; validation and the offline tests do not.

## Limitations

The helper is intentionally small. It does not configure credentials, deploy an API, infer provider access from installed tools, or guarantee that a remote is trustworthy. Review the repository URL and workspace path before cloning. The first iteration should be validated by CI and local tests before broader adoption.
