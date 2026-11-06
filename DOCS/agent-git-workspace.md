# Safe local Git workspace helper

`scripts/git-workspace.py` is a provider-neutral, standard-library-only helper for agents that have a local Git runtime. It is deliberately separate from the Agent Skills registry: it inspects a checkout and fetches its `origin`, but it does not push, merge, reset, switch branches, create forks, or change repository permissions.

## Capability discovery

Run:

```sh
python3 scripts/git-workspace.py capabilities
```

The result reports whether `git` and the GitHub CLI (`gh`) are installed. It does **not** test credentials, provider API connectivity, or whether a provider API is configured. If Git is unavailable, use the API/web access already provided by your agent environment; do not assume an API endpoint or shell exists.

## Clone into a new directory

```sh
python3 scripts/git-workspace.py clone https://github.com/OWNER/REPOSITORY --destination ./work/REPOSITORY
```

The destination must not already exist. The helper only accepts credential-free HTTPS URLs with a host and exactly one owner/repository path. It does not create a fork or push anything. Authentication, if required, should be handled by the Git/provider tooling configured in the environment; never put tokens in repository URLs.

## Inspect before acting

```sh
python3 scripts/git-workspace.py status ./work/REPOSITORY
python3 scripts/git-workspace.py diff ./work/REPOSITORY
```

Status reports the normalized HTTPS `origin`, checked-out branch (or detached HEAD), commit SHA, and staged/unstaged/untracked state. The first iteration intentionally supports HTTPS `origin` URLs; SSH/scp-style remotes are reported as unsupported rather than guessed. A dirty tree is reported, not cleaned or reset.

## Fetch safely

```sh
python3 scripts/git-workspace.py fetch ./work/REPOSITORY
```

Fetch updates Git's remote-tracking data only. It does not change the checked-out branch, merge or rebase, modify tracked working files, or push to a remote. The helper reports status before and after the fetch so an agent can check for concurrent local edits. Review the diff and working-tree state before proposing any write.

## Safety and limitations

- Repository URLs are validated before a clone is attempted; embedded credentials, non-HTTPS schemes, ports, query strings, fragments, and unexpected path components are rejected.
- Clone refuses to reuse any existing destination, including a non-empty directory.
- Status and diff are read-only. Fetch contacts the configured `origin`, but does not write to that remote.
- No operation performs a reset, checkout, merge, rebase, push, fork creation, or branch deletion.
- Network-dependent clone/fetch behavior is not covered by offline tests. Offline tests cover URL validation, destination preservation, dirty-tree reporting, and capability reporting.
- GitHub CLI availability is informational only. The helper is not tied to GitHub and does not invoke `gh`.

Related: [Agent Skills API](agent-skills-api.md) and [issue #698](https://github.com/Interested-Deving-1896/fork-sync-all/issues/698).
