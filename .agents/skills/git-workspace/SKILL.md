---
name: git-workspace
description: Safely clone, inspect, diff, and fetch a local Git checkout without implicit writes or destructive branch operations.
compatibility: Requires Python 3; local Git operations also require Git installed and an HTTPS repository URL for clone.
metadata:
  category: repository-maintenance
  risk: read-only-by-default
allowed-tools: Bash(python3 scripts/git-workspace.py *)
---

# Safe Git workspace operations

Use this skill only when a local shell and Git are available. Do not assume they are available in every agent environment.

1. Run `python3 scripts/git-workspace.py capabilities` and report what it actually detects. It does not verify credentials or provider API connectivity.
2. For a new checkout, use `clone URL --destination PATH`. The destination must not exist. Do not embed tokens or credentials in the URL.
3. Before any analysis, run `status PATH` and inspect the branch, HEAD, origin, and working-tree state.
4. If the tree is dirty, preserve it. Read `diff PATH` before suggesting or applying changes. Never reset, clean, stash, or overwrite local work as part of this skill.
5. Use `fetch PATH` only when updating origin's remote-tracking data is useful. Fetch does not merge, rebase, switch branches, or update working files; compare the reported before/after state.
6. If local Git is unavailable, say so and use the provider API/web interface only if that capability is already available. Do not invent or assume an API endpoint.
7. Treat fork creation, branch changes, commits, pushes, merges, settings changes, and remote writes as separate gated actions requiring explicit authorization.

See [the full workflow and limitations](../../../DOCS/agent-git-workspace.md).

This helper intentionally supports HTTPS remotes in its first iteration. SSH/scp-style origin URLs are not guessed or silently rewritten.
