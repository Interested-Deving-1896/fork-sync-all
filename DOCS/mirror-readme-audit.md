# Mirror-chain README audit

The mirror README audit discovers the repositories that currently exist in
the OpenOS-Project-OSP and OpenOS-Project-Ecosystem-OOC namespaces. It does not
assume that every planned repository in a registry is already live.

For normal mirrored projects it checks:

- a corresponding Interested-Deving-1896 source repository and README;
- one visible H1, the neutral managed headings, and balanced AI-owned blocks;
- the standard project badge;
- presence in both GitHub mirror namespaces; and
- README equality from the canonical source through both downstream mirrors.

Profile repositories, downstream-native publications, and explicitly custom
mirror repositories are classified in `config/mirror-readme-baseline.json`
with a reason instead of being silently omitted.

## Commands

```bash
GH_TOKEN=... python3 scripts/audit-mirror-readmes.py \
  --output-json mirror-readme-audit.json \
  --output-markdown mirror-readme-audit.md \
  --fail-on-findings

python3 scripts/repair-readme-structure.py README.md --check
```

The repair command only inserts a missing heading immediately before an
existing managed block. It does not generate prose or modify block content.
The `Update READMEs` workflow exposes the same behavior as `structure_only` for
safe bulk reconciliation.

`Mirror README Audit` runs weekly and maintains one issue dashboard. Use
`Mirror Orgs` with a comma-separated exact repository list to promote reviewed
source repairs to both downstream namespaces without sweeping unrelated or
merely planned repositories.
