# Organization profile READMEs

Fork-Sync-All renders the OSP and OOC GitHub organization profiles from the
canonical `Interested-Deving-1896/Interested-Deving-1896` profile README.
Downstream profiles inherit factual ecosystem sections and add their own chain
role, links, mascot expression, and digital cosplay costume.

## Configuration

`config/profile-readmes.yml` defines:

- The canonical source repository and README path
- Source sections that every downstream profile inherits
- Destination `.github` repositories and output paths
- Organization-specific role text and links
- Relay mascot expressions and Nexus costume variants

The configuration is parsed with `yaml.safe_load`.

## Render locally

```bash
python3 scripts/render-profile-readmes.py \
  --source ../Interested-Deving-1896/README.md \
  --output-dir /tmp/fsa-profile-readmes
```

This produces:

```text
/tmp/fsa-profile-readmes/
├── osp/profile/README.md
└── ooc/profile/README.md
```

Pass `--source-commit SHA` to pin an explicit provenance marker. Otherwise the
renderer resolves the Git commit containing the source README.

## Drift check

Render once, then compare the expected content without writing:

```bash
python3 scripts/render-profile-readmes.py \
  --source ../Interested-Deving-1896/README.md \
  --output-dir /tmp/fsa-profile-readmes \
  --check
```

The check returns `1` when either destination is absent or differs and `2` for
invalid configuration or source content.

## Publication

Copy each generated file to `profile/README.md` in the matching public
organization `.github` repository:

- `OpenOS-Project-OSP/.github`
- `OpenOS-Project-Ecosystem-OOC/.github`

Generated files include their source commit and a do-not-edit marker. Update
the canonical profile or `config/profile-readmes.yml`, regenerate, and publish
instead of editing a destination directly.

This mechanism is intentionally runner-neutral. It can run locally, on a
self-hosted runner, or as a step in an existing mirror operation without adding
a new scheduled GitHub-hosted workflow.
