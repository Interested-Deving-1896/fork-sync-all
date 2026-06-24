# Open NotebookLM (gabrielchua)

Generated outputs from [open-notebooklm](https://github.com/gabrielchua/open-notebooklm) —
a lightweight PDF-to-podcast converter using open-source LLMs and TTS — using fork-sync-all
documentation as source material.

Uses Llama 3.3 70B via Fireworks AI for dialogue generation and MeloTTS/Bark for speech synthesis.
Input: PDF. Output: MP3 podcast dialogue.

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
| [`audio-overview/`](audio-overview/) | PDF-to-podcast conversion | `.mp3` |

## Backend configuration

Configured in [`config/notebooklm-backends.yml`](../../config/notebooklm-backends.yml) under `id: open-notebooklm`.

Required secrets: `FIREWORKS_API_KEY`

## Generating content

```bash
gh workflow run generate-notebooklm.yml \
  --field backend=open-notebooklm \
  --field content_types=audio-overview \
  --field source_pdf=docs/SUMMARY.pdf
```
