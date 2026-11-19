# AI agent badges

Fork-Sync-All uses provider-neutral README badges instead of treating one hosted
development environment as the universal entry point. The primary **AI agent
ready** badge describes repository compatibility; the badges beside it are
shortcuts to supported agent surfaces, not claims that a provider authored or
endorses the project.

The machine-readable registry is `config/ai-agent-badges.json`. Add or retire a
provider there rather than adding provider-specific conditionals to README
scripts. `scripts/agent-badge-registry.py` validates the registry, renders the
managed Markdown, and removes both current managed badges and legacy Ona badges
during migration.

## Desktop and mobile capabilities

| Provider | Desktop/web | iOS | Android | Mobile behavior |
|---|---|---|---|---|
| OpenAI Codex | Cloud or a connected Mac/Windows host | Supported | Supported | Start, steer, approve, and review cloud or remote tasks |
| Claude Code | Web, desktop, cloud, or SSH | Supported for documented remote sessions | Not documented here | Monitor cloud sessions or remotely control a supported session |
| GitHub Copilot | GitHub, Copilot app, IDE, or CLI | GitHub Mobile | GitHub Mobile | Repository chat; supported CLI sessions can be steered remotely |
| Cursor | Desktop or web background agents | PWA | PWA | Start background agents and hand work back to desktop |
| Gemini CLI | Local terminal or Cloud Shell | No coding-agent mobile control documented | No coding-agent mobile control documented | Use the terminal surface; the consumer Gemini app is not a CLI remote control |

Mobile capability is metadata, not an emulation layer. Each provider owns its
authentication, relay, approvals, and remote-execution security. Fork-Sync-All
therefore uses normal HTTPS launch links and records provider capabilities
without proxying credentials or exposing an agent server publicly.

For Codex, the phone is a control plane: work runs in Codex Cloud or on the
connected computer. Pair a trusted iOS or Android device from the ChatGPT
desktop app under **Settings → Connections → Control this Mac or PC**. Keep a
connected host awake and online for host-backed work; cloud tasks do not require
the computer to remain awake.

## Adding another provider

Add a unique provider object with an HTTPS badge image, launch URL, supported
surfaces, mobile mode, and official documentation URL. Providers are disabled
by setting `enabled` to `false`. Validate and preview the result with:

```bash
python3 scripts/agent-badge-registry.py validate
python3 scripts/agent-badge-registry.py render \
  --repo-url https://github.com/OWNER/REPOSITORY
```

Keep README image URLs on trusted hosts such as `img.shields.io`, and do not
invent repository deep links for providers that do not document one.
