# Open Notebook

Generated outputs from [Open Notebook](https://github.com/lfnovo/open-notebook) — a self-hosted,
multi-model NotebookLM alternative — using fork-sync-all documentation as source material.

Open Notebook supports 18+ AI providers (OpenAI, Anthropic, Ollama, Gemini, etc.) and runs
locally via Docker Compose (SurrealDB + open_notebook image).

**Directory structure:**
```
<type>/
  <variant>/
    README.md          — variant description + file index
    <YYYY-MM-DD>/
      README.md        — session log for that date
      <generated files>
```

Each subdirectory corresponds to an output type:

| Directory | Type | Format |
|---|---|---|
| [`audio-overview/`](audio-overview/) | Podcast / Audio Overview | `.mp3` / `.wav` |
| [`reports/`](reports/) | Content transformations | `.pdf` / `.md` |

## Backend configuration

Configured in [`config/notebooklm-backends.yml`](../../config/notebooklm-backends.yml) under `id: open-notebook`.

Required secrets: `OPEN_NOTEBOOK_URL`, `OPEN_NOTEBOOK_API_KEY`

## Generating content

```bash
gh workflow run generate-notebooklm.yml \
  --field backend=open-notebook \
  --field content_types=audio-overview
```
