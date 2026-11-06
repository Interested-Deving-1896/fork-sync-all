# Documentation capabilities

Fork-Sync-All uses a versioned, provider-neutral manifest at
`config/documentation-capabilities.json` to describe verified documentation
destinations. Markdown remains canonical; README, mdBook, and GitBook are
consumers rather than competing sources.

## Capability rules

- **Language:** only a translation marked `verified: true` is eligible for
  rendering. If the requested language is unavailable, the renderer falls back
  to the verified default language.
- **Read aloud:** a link is rendered only when a real page-level speech adapter
  has an HTTPS destination and both `enabled` and `verified` are true. A
  generated audio overview is not represented as interactive page narration.
- **Braille:** a link is rendered only when a verified Braille-ready semantic
  document endpoint is configured. This does not claim physical display
  detection or device control.
- **Formats:** README and book destinations are explicit HTTPS URLs. A format
  is not advertised merely because an exporter exists in the repository.

Static Markdown badges are links, not application controls. Interactive
documentation frontends may consume the same manifest and expose equivalent
keyboard-operable links or controls with localized accessible names.

## Validate and preview

```bash
python3 scripts/documentation-capability-registry.py --validate
python3 scripts/documentation-capability-registry.py --document README.md --language en
python3 -m pytest -q tests/test_documentation_capability_registry.py
```

Keep rollout opt-in. Do not infer translations, speech support, Braille device
support, or published destinations from installed tools or repository names.
