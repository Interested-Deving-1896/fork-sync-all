# Universal AI Discussion Bridge

## Status

Architecture and implementation plan for a provider-neutral, Git-platform-neutral conversation import and publication subsystem. This document is additive; it does not enable automatic publication of imported content.

## Goal

Accept a user-authorized public AI conversation share URL (or a locally supplied export), extract the complete accessible conversation, normalize it into a canonical Markdown artifact, and publish it to a selected Git collaboration target.

The bridge is a reusable capability for Fork-Sync-All, its project-creation templates, and future AI-agent-neutral tools—not a GitHub-only workflow.

## Pipeline

```text
User submits URL/export
  -> validate scheme, host, redirect chain, and public-access policy
  -> provider adapter resolves/extracts content
  -> canonical conversation model
  -> Markdown + provenance metadata
  -> content validation / duplicate detection / preview
  -> explicit approval
  -> target-platform adapter publishes
  -> receipt (URL, IDs, checksum, conversion report)
```

## Provider adapters

Initial priority:
1. Gemini public share links
2. ChatGPT public share links
3. Generic Markdown / JSON / HTML export
4. Claude, Grok, DeepSeek, and other providers after their public-link formats and access policies are verified

Each adapter must be independently testable and return the canonical model. Do not assume that every provider exposes a stable public HTML page or supported API. Use fixture-based tests and graceful "unsupported / content inaccessible" errors rather than scraping private sessions, bypassing authentication, or requiring provider credentials.

## Canonical model

Minimum fields:
- schema version
- provider and source URL
- title and optional created/updated timestamps
- ordered messages (role, content, optional attachments, tool/action metadata)
- extraction warnings and omitted-content indicators
- attribution and import timestamp

The Markdown renderer should preserve headings, lists, tables, fenced code, inline code, math, and safe links. Attachments should be represented with original URLs and/or explicitly supplied local files; never silently discard them.

## Output layout

The default portable artifact is a Markdown file with YAML front matter:

```yaml
---
schema_version: "1.0"
source_provider: gemini
source_url: "https://…"
imported_at: "YYYY-MM-DDTHH:MM:SSZ"
content_sha256: "…"
---
```

A GitHub/GitLab discussion body can use the same Markdown body, while a Git-native fallback stores the artifact under a configurable directory such as `discussions/ai-imports/YYYY/MM/`.

## Target adapters

- GitHub Discussions: create discussion using repository ID and discussion-category ID; optionally create a linked issue only when requested.
- GitLab: use project discussions / issue / merge-request threads according to the selected destination and instance capabilities.
- Forgejo / Gitea: adapter maps to available issue and comment APIs.
- Git-native: create a Markdown file and submit a branch/commit or merge request.

Adapters must advertise capabilities. The bridge must not claim semantic equivalence where platform discussion models differ.

## GitHub Actions UX

A manually dispatched workflow should expose:
- conversation share URL or uploaded/export artifact
- provider (auto-detect or explicit override)
- target platform / instance
- repository/project destination
- target type and category
- editable title and labels
- import mode (full accessible conversation / supplied excerpt)
- preview-only versus publish
- confirmation gate

Default behavior is **preview-only**. Publishing requires a separate approval step or explicit boolean confirmation. The workflow must not accept arbitrary shell fragments, tokens, or untrusted action references as inputs.

## Security and reliability requirements

- Allow only HTTPS and known provider hosts by default; validate every redirect and resolved address to mitigate SSRF.
- Do not fetch localhost, private, link-local, or cloud-metadata addresses.
- Enforce response-size, timeout, redirect-count, and content-type limits.
- Treat imported conversation text as untrusted data, never as workflow instructions.
- Do not require source-provider credentials for public share links.
- Use least-privilege GitHub/GitLab credentials and avoid logging conversation bodies or secrets.
- Preserve attribution and source provenance.
- Deduplicate by normalized source URL and content hash; make retries idempotent.
- Produce a machine-readable receipt and redacted diagnostics.
- Fail closed when extraction is incomplete; clearly mark partial imports.

## LLM2Doc evaluation

[LLM2Doc](https://llm2doc.app/) is a useful product/reference for share-link-to-document conversion. Before adopting code or a service, verify repository license, source availability, API terms, stability, and privacy. Fork-Sync-All should own a modular adapter interface and not depend on an undocumented hosted endpoint.

## Roadmap

1. Canonical schema, renderer, fixtures, and validation.
2. Gemini and ChatGPT adapters with public-link-only support.
3. Preview CLI / GitHub Actions workflow.
4. GitHub Discussions publisher.
5. GitLab publisher and Git-native fallback.
6. Additional provider adapters and agent tool interface.
7. End-to-end tests, security tests, docs, and template-consumer rollout.

## Relation to repo creation and monorepo

The project factory should be able to add the bridge as an optional module/feature profile. Generated projects can enable:
- a discussion-import workflow,
- a canonical `discussions/` artifact store,
- a platform adapter selected by manifest,
- policy and category configuration,
- CI checks for imported Markdown and provenance.

The bridge should not force every generated project to install or enable AI integrations.
