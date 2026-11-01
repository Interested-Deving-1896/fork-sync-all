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


## GitHub Actions preview

Use the repository's **Actions → AI Discussion Bridge Preview → Run workflow** interface to validate and render a canonical JSON conversation. Paste the JSON into the \`conversation_json\` field. The workflow:
1. writes input through an environment variable (not interpolated into shell source);
2. validates the schema;
3. renders Markdown;
4. uploads a Markdown artifact for seven days.

This workflow is **preview-only**: it creates no GitHub Discussion, issue, commit, or GitLab thread. It accepts canonical JSON, not raw provider share links. Share-link extraction is intentionally not implemented until provider-specific extraction, network safety, and fixture validation are complete.

See \`.github/workflows/ai-discussion-bridge-preview.yml\`.
