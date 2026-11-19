# infra-dashboard

Unified infrastructure platform — status pages, mirror management, build dashboards, and pastebin.

Config-driven and agnostic: works with any GitHub org, any mirror chain, any Linux distribution, any hardware architecture.

## Components

| Component | Description |
|---|---|
| `statuspage/` | Service status page |
| `public-dashboard/` | Package search and browse UI |
| `builder-dashboard/` | Build system dashboard |
| `rate-mirrors/` | Mirror ranking CLI — multi-distro |
| `mirrorlist-proxy/` | Cached mirrorlist proxy |
| `bin-pastebin/` | Self-contained pastebin server |

## Configuration

All org/distro-specific values live in `config/infra.toml`. See `config/infra.example.toml` for a full reference.

## Getting Started

```bash
cp config/infra.example.toml config/infra.toml
# Edit config/infra.toml with your org and API settings
```

Each component can be run independently or together via the root `docker-compose.yml`.
