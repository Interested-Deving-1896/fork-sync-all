# Dependency vulnerability audit

The dependency-risk audit turns the three GitHub namespaces' open Dependabot
alerts into one prioritized backlog. It reports counts by severity and project,
links every displayed advisory to its native alert, and keeps the complete data
in a JSON artifact.

The policy is `config/dependency-risk-policy.json`. Its `namespace_kinds` map
distinguishes GitHub user namespaces, which require per-project reads, from
organizations, which have an aggregate alert endpoint. Critical alerts fail the
scheduled gate by default. A temporary repository exception must name an owner
and an expiry in its reason; exceptions remain visible in the report and are
never silently discarded.

The workflow needs a token able to read organization Dependabot alerts. The
repository `GITHUB_TOKEN` only covers its own repository, so the chain-wide run
uses `SYNC_TOKEN` and will report an authorization error if that token lacks
Dependabot/security-event read access.

User-namespace reads are restricted to projects in
`config/live-chain-manifest.json`; the audit never expands to every repository
owned by the account.

Run it locally with:

```bash
GH_TOKEN=... python3 scripts/audit-dependency-risk.py \
  --output-json dependency-risk.json \
  --output-markdown dependency-risk.md \
  --fail-on-policy
```

Triage critical findings first. Prefer an available patched version; when no
patch exists, isolate or replace the dependency and record the decision in its
own project rather than weakening the central threshold.
