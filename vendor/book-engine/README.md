# book-engine

Agnostic documentation book backend for fork-sync-all and OSP-bound consumer repos.

Provides a unified source format (Markdown + SUMMARY.md) that can be exported to
any of the supported engines at runtime. Each engine is an independent adapter under
`adapters/`. The `scripts/export.sh` driver selects the target engine and delegates.

## Supported engines

| Engine | Adapter | Output | Deploy target |
|---|---|---|---|
| **mdBook** | `adapters/mdbook.sh` | Static HTML | GitHub Pages (`gh-pages` branch) |
| **MkDocs** | `adapters/mkdocs.sh` | Static HTML | GitHub Pages or Netlify |
| **Docusaurus** | `adapters/docusaurus.sh` | React SPA | GitHub Pages or Vercel |
| **GitBook CLI** | `adapters/gitbook.sh` | Static HTML | GitHub Pages or gitbook.com |
| **Pandoc PDF** | `adapters/pandoc.sh` | PDF + EPUB | Release artifact |

## Usage

```bash
# Build with default engine (mdBook)
bash vendor/book-engine/scripts/export.sh

# Build with a specific engine
BOOK_ENGINE=mkdocs bash vendor/book-engine/scripts/export.sh

# Build all engines (CI matrix)
BOOK_ENGINE=all bash vendor/book-engine/scripts/export.sh

# Dry-run (validate config only)
BOOK_ENGINE=mdbook DRY_RUN=true bash vendor/book-engine/scripts/export.sh
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BOOK_ENGINE` | `mdbook` | Target engine: `mdbook`, `mkdocs`, `docusaurus`, `gitbook`, `pandoc`, `all` |
| `BOOK_SRC` | `DOCS` | Source directory containing Markdown files and SUMMARY.md |
| `BOOK_OUT` | `book` | Output directory |
| `BOOK_TITLE` | from `book.toml` | Override book title |
| `BOOK_THEME` | `fsa` | Theme name under `vendor/book-engine/themes/` |
| `BOOK_BRAND_DIR` | `assets/brand` | Directory containing logo PNGs |
| `BOOK_LOGO` | `logo-option-1.png` | Primary logo filename |
| `DRY_RUN` | `false` | Validate and print plan without building |
| `FSA_API_URL` | `http://localhost:8788` | FSA MCP server for live data injection |

## Source format

The canonical source is standard CommonMark Markdown with a `SUMMARY.md` navigation
file (mdBook convention). All adapters translate `SUMMARY.md` into their native nav
format automatically:

- mdBook: uses `SUMMARY.md` natively
- MkDocs: `scripts/export.sh` generates `mkdocs.yml` `nav:` from `SUMMARY.md`
- Docusaurus: generates `sidebars.js` from `SUMMARY.md`
- GitBook: uses `SUMMARY.md` natively (GitBook CLI v2 compatible)
- Pandoc: concatenates all pages in SUMMARY.md order into a single document

## Theme

The `themes/fsa/` directory contains the FSA brand theme:
- `custom.css` — color variables, typography, logo placement
- `cover.html` — book cover page (used by mdBook + Pandoc)
- `favicon.png` — favicon derived from logo-option-1.png
- `head.hbs` — mdBook head partial (injects CSS + favicon)

The same CSS variables are reused across all engine adapters via adapter-specific
wrappers (`mkdocs-extra.css`, `docusaurus-custom.css`).

## Adding a new engine

1. Create `adapters/<engine>.sh` implementing the `build()` function
2. Add an entry to `config/engines.yml`
3. Add the engine to the matrix in `.github/workflows/book-export.yml`
