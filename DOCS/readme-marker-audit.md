# README ownership-marker audit

`scripts/readme-marker-audit.py` is a read-only preflight tool for the ownership
markers currently used by `scripts/update-readmes.sh`:

- `<!-- AI:start:SECTION -->` / `<!-- AI:end:SECTION -->`
- `<!-- HUMAN:start -->` / `<!-- HUMAN:end -->`
- `<!-- LTS:start:SECTION -->` / `<!-- LTS:end:SECTION -->`

It reports malformed, duplicate, mismatched, unmatched, and unclosed marker
regions. Nested regions are accepted when their markers are properly balanced.
The tool reports errors with line numbers and exits non-zero if any input file
is unreadable or structurally invalid.

Run it against one or more local README files:

```bash
python3 scripts/readme-marker-audit.py README.md path/to/another/README.md
python3 -m unittest discover -s tests -p 'test_readme_marker_audit.py'
```

## Safety and integration boundary

This is deliberately a separate, read-only preflight auditor. It does not
rewrite content, call a provider API, fetch repositories, or change the
existing README updater. The current updater's extraction and replacement
functions remain authoritative until their behavior is fully characterized
and a reviewed integration plan exists. In particular, a passing audit does
not prove that a downstream writer has correct repository scope or permission.

The auditor is an initial structural contract, not yet a complete parser for
every legacy README convention. Before it is wired into a writer, characterize
existing fixtures and add compatibility tests for real-world marker layouts.
