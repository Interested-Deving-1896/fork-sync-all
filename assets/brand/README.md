# Brand assets

Identity assets for all fork-sync-all instances. This directory is the
single source of truth — all three variants live here and flow through
the mirror chain unchanged.

## Structure

```
assets/brand/
  source/          ← Interested-Deving-1896 identity
  osp/             ← OpenOS-Project-OSP + openos-project (GitLab) — shared identity
  ooc/             ← OpenOS-Project-Ecosystem-OOC + openos-project-ooc-ecosystem — shared identity
  .active/         ← Runtime output (gitignored — written by reconcile-identity-assets.sh)
```

## How it works

`scripts/reconcile-identity-assets.sh` detects which instance it is running
on (via `fsa-node-identity.sh`), selects the matching variant directory, and
writes the active assets to `.active/`. The `.active/` directory is gitignored
and never committed — it is regenerated on every run.

The cover page (`DOCS/cover.md`) uses `<!-- FSA-IDENTITY-* -->` markers that
the reconcile script fills in at doc-build time.

## Adding logos

Drop your logo files into the appropriate variant directory:

```
assets/brand/source/logo.svg      ← source instance logo
assets/brand/osp/logo.svg         ← OSP mirror logo
assets/brand/ooc/logo.svg         ← OOC mirror logo
```

SVG is preferred. PNG fallbacks are also supported (`logo.png`, `logo-dark.png`).

## GitLab → GitHub pull safety

The pull leg of `git-platform-sync.yml` pushes the full repo including this
directory. That is safe because:

1. All three variant dirs are committed identically on every instance.
2. `.active/` is gitignored — it is never committed and cannot be overwritten
   by a git push.
3. The reconcile script writes to `.active/` at runtime, not to the variant
   dirs — so a pull from GitLab cannot corrupt the source variant.

See `config/identity-assets.yml` for the deployment→variant mapping.
