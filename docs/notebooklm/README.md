# NotebookLM

Generated outputs from [Google NotebookLM](https://notebooklm.google.com/) using fork-sync-all documentation as source material.

Each subdirectory corresponds to a NotebookLM generation type, with variant
subdirectories matching the customization options available in NotebookLM Studio,
and date-stamped subdirectories (`YYYY-MM-DD/`) for each generation session.

**Directory structure:**
```
<type>/
  <variant>/
    README.md          — variant description + file index
    <YYYY-MM-DD>/
      README.md        — session log for that date
      <generated files>
```

Each subdirectory corresponds to a NotebookLM generation type:

| Directory | Type | Format |
|---|---|---|
| [`audio-overview/`](audio-overview/) | Audio Overview | `.mp3` / `.wav` |
| [`video-overview/`](video-overview/) | Video Overview | `.mp4` |
| [`slide-deck/`](slide-deck/) | Slide Deck | `.pdf` / `.pptx` / `.gslides` |
| [`flashcards/`](flashcards/) | Flashcards | `.pdf` / `.csv` |
| [`quiz/`](quiz/) | Quiz | `.pdf` / `.md` |
| [`infographic/`](infographic/) | Infographic | `.pdf` / `.png` |
| [`reports/`](reports/) | Reports | `.pdf` / `.md` |

## Source material

The NotebookLM notebooks for this project use the following sources:

- `DOCS/` — mdBook documentation pages
- `docs/workflow-triggers.md` — full workflow reference
- `AGENTS.md` — conventions and patterns for AI agents
- `README.md` — project overview

## Naming convention

Files should be named to indicate the content and date:

```
<topic>-<YYYY-MM-DD>.<ext>
```

Examples:
- `audio-overview/full-pipeline-overview-2026-06-09.mp3`
- `slide-deck/mirror-chain-architecture-2026-06-09.pdf`
- `reports/quota-analysis-2026-06-09.pdf`
