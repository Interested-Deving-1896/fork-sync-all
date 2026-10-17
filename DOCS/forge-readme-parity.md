# Forge README parity and link audit

`Forge README Parity` runs two independent checks against the README subsystem.

The parity job reads enabled surfaces from `config/fsa-deployments.yml`. It uses
the shared platform adapter to enumerate projects and retrieve `README.md` from
GitHub, GitLab, Gitea, Forgejo, or Codeberg. GitLab root groups are traversed
recursively so subgroup placement does not hide a project. Observed downstream
projects are matched by project name to the canonical `source` deployment and
their README SHA-256 digests are compared. Documented exceptions in
`config/mirror-readme-baseline.json` remain out of scope.

The external-link job clones the Interested-Deving-1896, OSP, and OOC profile
projects and checks their Markdown files. `scripts/check-markdown-links.py` uses
a Markdown-aware tokenizer: fenced and indented code, inline code, comments,
images, local fragments, and non-HTTP schemes are excluded. Inline links,
reference definitions, autolinks, and HTML anchors are checked once per unique
URL with bounded retries for transient network and server errors. JSON and
Markdown reports retain every source-file and line-number occurrence.
The profile workflow records HTTP 403 responses as allowed because several
working community-link services reject automated clients; the status remains
visible in JSON rather than being discarded.

## Local commands

```bash
python3 -m pip install pyyaml
GH_TOKEN=... GITLAB_TOKEN=... \
  python3 scripts/audit-forge-readme-parity.py \
    --output-json /tmp/forge-readme-parity.json \
    --output-markdown /tmp/forge-readme-parity.md \
    --fail-on-findings

python3 scripts/check-markdown-links.py README.md DOCS \
  --output-json /tmp/markdown-link-audit.json \
  --output-markdown /tmp/markdown-link-audit.md
```

Adding an enabled deployment to `config/fsa-deployments.yml` automatically
includes it in the audit. Configure the corresponding platform token in Actions;
the collector reports a missing token instead of silently skipping the surface.
