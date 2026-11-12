# Code Archaeology Engine

**Status:** local-Git read-only MVP slice (v0.1.0); not the complete provider-neutral engine.

The executable is scripts/code_archaeology.py. It is a bounded evidence collector, not an autonomous code repair agent or provider orchestration engine.

## Usage

```sh
python3 scripts/code_archaeology.py --repo . --revision HEAD
python3 scripts/code_archaeology.py --repo . --path scripts/branch-topology.py
python3 scripts/code_archaeology.py --repo . --path scripts/branch-topology.py --start 40 --end 65
python3 scripts/code_archaeology.py --repo . --path scripts/branch-topology.py --pickaxe 'comparison_consistent'
python3 scripts/code_archaeology.py --repo . --pickaxe 'branch topology' --regex --format markdown
```

JSON is the default output. Markdown is a concise human-readable rendering. Reports include the resolved commit, recent commit metadata, local refs, optional blame porcelain, optional pickaxe matches, execution policy and limitations.

## Safety contract

- Read-only: no checkout, index/worktree write, ref update, commit, push, provider API call, workflow dispatch or PR creation.
- Uses explicit Git argument arrays; no shell is invoked.
- Child Git calls disable hooks and fsmonitor; no repository scripts, hooks, filters, builds or workflows are intentionally executed.
- No network operation is made.
- Query limits, path validation and subprocess timeouts are bounded.
- Repository content and commit metadata are untrusted evidence. Author fields are not verified identity.

## Evidence interpretation and limits

- Raw git blame --line-porcelain output is preserved rather than flattened into an ownership claim.
- Literal pickaxe uses git log -S; regex pickaxe uses git log -G. Matches locate diff changes but do not establish intent or causality.
- Non-shallow history is labelled local_object_database_only, not guaranteed complete. Shallow repositories are marked shallow_or_incomplete.
- No provider PR/MR correlation, rename-following analysis, moved/copied-line detection, cross-repository lineage, symbol graph or maintainer inference is implemented yet.

## Tests

Run: python3 -m unittest tests.test_code_archaeology -v

The focused tests create temporary local Git repositories and cover read-only behavior, blame evidence, pickaxe discovery, path validation, bounded limits and limitation disclosure.

## Next gates

1. Add fixtures for renames, moved/copied lines, merges, shallow/missing objects, ignore-revs, cherry-picks, reverts and backports.
2. Add provider-neutral evidence interfaces, then GitHub and GitLab adapters with pagination completeness, permission and rate-limit reporting.
3. Consume the Reference Management and Branch Topology contracts; do not create a second topology/ref writer.
4. Integrate with audit/reporting only after exact-head tests and a narrow allowlisted read-only pilot.
5. Keep AI narratives grounded in stable commit/path/line/provider evidence; keep repair and mutation outside this engine.

This implementation slice is not a claim that the full engine is complete. Provider correlation, cross-repository lineage, structural indexing, broader fixture coverage and CI integration remain open.
