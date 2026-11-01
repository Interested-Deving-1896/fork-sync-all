# AI Discussion Bridge (initial core)

Offline-first core for validating AI conversation exports and rendering portable Markdown. It does **not** fetch arbitrary share URLs or publish to Git hosting yet; provider extraction and publication need separately reviewed adapters and integration tests.

## Quick start

```bash
python3 scripts/ai-discussion-bridge/bridge.py validate conversation.json
python3 scripts/ai-discussion-bridge/bridge.py render conversation.json --output conversation.md
```

Input JSON includes `schema_version`, `source` (`provider`, optional `url`), `title`, and ordered `messages` (`role`, `content`). See `examples/gemini-conversation.json`.

## Security boundary

This version reads only a caller-selected local file, makes no network requests, reads no provider credentials, and publishes nothing. Imported text is data, never executable instructions. Public-share retrieval must later implement redirect/IP SSRF checks, resource limits, and partial-import reporting before activation.
