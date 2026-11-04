# Programming-language README badges

Fork-Sync-All keeps programming-language badges separate from AI-agent, KDE
Eco, Blue Angel, certification, and workflow-status badges. The registry at
`config/programming-language-badges.json` is the single source of truth for
canonical labels, colors, and optional Simple Icons slugs.

## Evidence and rendering

The injector consumes the source-control provider's language metadata endpoint
(GitHub repository languages or GitLab project languages). It does not infer
languages from repository names, descriptions, topics, README prose, or agent
configuration. Language metadata is an evidence-backed classification signal,
not proof of code quality, maturity, buildability, or certification.

Multiple detected languages are rendered in deterministic descending provider
measure order (GitHub byte counts or GitLab percentages), with canonical name
as the tie-breaker. Languages not yet in the
registry are represented by a neutral **Other languages / unclassified**
badge rather than being silently dropped. An authoritative empty language
response is shown as **Language undetected**. An unavailable or error response
is omitted; it is not misrepresented as an empty result.

The renderer validates registry colors and icon slugs, rejects malformed
language metadata, and escapes badge URL components. Language badges link to
GitHub Linguist's language-detection project for classification context.

## Safe rollout

The injector supports `LANGUAGE_BADGES=true`; it defaults to disabled so
existing repository READMEs are not broadly rewritten before review. Dry-run
first, inspect representative single-language, mixed-language, and
unclassified repositories, then enable rollout deliberately. The Fork-Sync-All
README's own language row should be updated only from a successful provider
metadata response.

## Local validation

```bash
python3 scripts/programming-language-badge-registry.py validate
python3 scripts/programming-language-badge-registry.py render --languages-json '{"Rust":1200,"Shell":500}'
python3 -m pytest tests/test_programming_language_badges.py -q
```
