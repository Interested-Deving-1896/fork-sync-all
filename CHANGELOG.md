# Changelog

All notable OTA releases are documented here. Entries are prepended
automatically by `ota-release.yml` when a new semver tag is pushed.

Format: `## vX.Y.Z — YYYY-MM-DD`

---

## v1.0.0 — 2026-05-27

### Initial OTA system release

Introduces the opt-in OTA update system for forks of fork-sync-all and
OSP-bound consumer repos.

**What's included in OTA payloads:**
- Repo-own source code and directory structure (per-repo, assembled at delivery time)
- Repo-own GitHub Actions workflows (anything not managed by template sync)
- OTA self-update machinery (`ota-opt-in.yml`, `ota-self-update.yml`)

**What OTA does NOT touch:**
- Shared infra workflows managed by template sync (defined in `config/template-manifest.yml`)
- `.ota/config.yml` fields managed automatically (`pinned_sha`, `pinned_at`, `ota_version`)
- Files listed in a repo's `exclude_paths`

**Mirror-chain exclusion:**
- `Interested-Deving-1896`, `OpenOS-Project-OSP`, `OpenOS-Project-Ecosystem-OOC`,
  `gitlab.com/openos-project` are excluded from OTA delivery by default
- Non-standalone profile consumers (`full`, `mirror`, `infra-core`) are excluded by default
- Both exclusions can be overridden with `mirror_chain_opt_in: true` in `.ota/config.yml`

**To opt in:** run the `OTA Opt-In` workflow_dispatch in your fork.

**Full release notes:** https://github.com/Interested-Deving-1896/fork-sync-all/releases/tag/v1.0.0
