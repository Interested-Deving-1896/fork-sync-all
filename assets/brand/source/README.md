# Brand assets — Interested-Deving-1896 (source)

Identity assets for the canonical source instance of fork-sync-all.

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

Drop your logo files here. `scripts/reconcile-identity-assets.sh` reads
from this directory when running on the source instance and writes the
active assets to `assets/brand/.active/` (gitignored, never committed).

The cover page markers in `DOCS/cover.md` are filled at doc-build time.
