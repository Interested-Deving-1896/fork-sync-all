# OpenBookLM

Generated outputs from [OpenBookLM](https://github.com/open-biz/OpenBookLM) — an open-source
audio course platform — using fork-sync-all documentation as source material.

OpenBookLM uses Cerebras API for LLM inference and Suno Bark for text-to-audio synthesis.
Supports multilingual course generation and community sharing.

**Directory structure:**
```
<type>/
  <variant>/
    README.md          — variant description + file index
    <YYYY-MM-DD>/
      README.md        — session log for that date
      <generated files>
```

| Directory | Type | Format |
|---|---|---|
| [`audio-overview/`](audio-overview/) | Audio course generation | `.mp3` / `.wav` |
| [`reports/`](reports/) | Course content export | `.pdf` / `.md` |

## Backend configuration

Configured in [`config/notebooklm-backends.yml`](../../config/notebooklm-backends.yml) under `id: openbooklm`.

Required secrets: `OPENBOOKLM_URL`, `CEREBRAS_API_KEY`

## Generating content

```bash
gh workflow run generate-notebooklm.yml \
  --field backend=openbooklm \
  --field content_types=audio-overview
```
