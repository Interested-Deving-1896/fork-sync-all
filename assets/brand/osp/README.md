# Brand assets — OpenOS-Project-OSP / openos-project (OSP mirror)

Identity assets for the OSP mirror instances of fork-sync-all.
Used on both OpenOS-Project-OSP (GitHub) and openos-project (GitLab) —
they share the same identity.

## Files

| File | Purpose |
|---|---|
| `logo.svg` | Primary logo (vector, preferred) |
| `logo.png` | Primary logo (raster, fallback) |
| `logo-dark.svg` | Dark-background variant |
| `logo-dark.png` | Dark-background variant (raster) |
| `cover-title.md` | Cover page title block (injected into DOCS/cover.md) |
| `cover-badge-extra.md` | Extra badges for this instance's cover page (optional) |

## Usage

Drop your OSP logo files here. `scripts/reconcile-identity-assets.sh`
reads from this directory when running on `osp-github` or `osp-gitlab`
and writes the active assets to `assets/brand/.active/` (gitignored).
