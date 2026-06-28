# Brand assets — OpenOS-Project-Ecosystem-OOC / openos-project-ooc-ecosystem (OOC mirror)

Identity assets for the OOC mirror instances of fork-sync-all.
Used on both OpenOS-Project-Ecosystem-OOC (GitHub) and
openos-project-ooc-ecosystem (GitLab) — they share the same identity.

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

Drop your OOC logo files here. `scripts/reconcile-identity-assets.sh`
reads from this directory when running on `ooc-github` or `ooc-gitlab`
and writes the active assets to `assets/brand/.active/` (gitignored).
