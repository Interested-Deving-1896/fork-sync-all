# Eco Audit

> Generated 2026-06-17 by `scripts/eco/eco-audit.sh`
> Aligned with [KDE Eco](https://eco.kde.org/) / [Blue Angel DE-UZ 215](https://www.blauer-engel.de/en/certification/criteria) criteria.

## Score: 🟡 14/20 (70%) — B — Good

| Check | Score | Detail |
|---|---|---|
| ❌ green hosting | 0/2 | Green hosting (❌ Not verified green — hosted by unknown) |
| ✅ foss license | 2/2 | FOSS license present (LICENSE) |
| ✅ no telemetry | 2/2 | No telemetry/tracking found |
| ⚠️ no forced updates | 1/2 | Possible forced update patterns (7 hits — review manually) |
| ✅ concurrency groups | 2/2 | Concurrency groups: 114/116 workflows (98%) |
| ✅ graphql adoption | 2/2 | GraphQL adopted in 33 scripts (reduces API quota consumption) |
| ✅ dep minimalism | 2/2 | Low dependency footprint: 0.2 installs/workflow avg |
| ⚠️ carbon estimate | 1/2 | Carbon estimate available: ~27.13 kg CO2e/year (stub — KEcoLab needed for precision) |
| ❌ keco lab | 0/2 | KEcoLab: not yet configured (stub — requires GitLab CI + physical hardware) |
| ✅ old hardware | 2/2 | No minimum hardware requirements specified (shell scripts run on any hardware) |

---

## Carbon Footprint Estimate

| Parameter | Value | Source |
|---|---|---|
| Daily workflow runs | ~100 | Estimate |
| Avg job duration | ~3 min | Estimate |
| Runner TDP | ~30W | GitHub ubuntu-latest (2-core shared VM) |
| Azure PUE | 1.18 | Microsoft 2023 Sustainability Report |
| Grid intensity | 420 gCO2/kWh | EPA eGRID 2022, MROW (Azure North Central US) |
| **Annual estimate** | **~27.13 kg CO2e/year** | Proxy — not measured |

> ⚠️ This is a proxy estimate. Precise measurement requires [KEcoLab](#keco-lab-gitlab-stub).

---

## Green Hosting

- **URL checked:** `https://interested-deving-1896.github.io/fork-sync-all/`
- **Result:** ❌ Not verified green — hosted by unknown
- **Checker:** [Green Web Foundation](https://www.thegreenwebfoundation.org/)

---

## KEcoLab (GitLab Stub)

KEcoLab is KDE's remote energy measurement lab. It uses a physical power meter
connected to test hardware to measure actual watt-hours consumed per use case.

**This cannot run on GitHub Actions** — it requires physical hardware at KDE's
infrastructure. The stub below is ready to activate when hosted on GitLab.

### Setup steps

1. Write `KdeEcoTest` scripts simulating user interactions with your software
2. Add `.gitlab-ci-eco.yml` to your repo (template: `scripts/eco/gitlab-ci-eco.yml.tpl`)
3. Submit to KEcoLab: <https://invent.kde.org/teams/eco/remote-eco-lab>
4. Receive energy consumption report (watt-hours per use case)
5. Apply for Blue Angel DE-UZ 215 if criteria are met

### Resources

| Resource | URL |
|---|---|
| KEcoLab repository | <https://invent.kde.org/teams/eco/remote-eco-lab> |
| KDE Eco Handbook | <https://eco.kde.org/be4foss-handbook> |
| KdeEcoTest tool | <https://invent.kde.org/teams/eco/feep/-/tree/master/tools/KdeEcoTest> |
| Blue Angel criteria | <https://www.blauer-engel.de/en/certification/criteria> |
| Criteria PDF (DE-UZ 215) | <https://www.blauer-engel.de/sites/default/files/vergabegrundlagen-dokumente/DE-UZ-215-Vergabegrundlagen-2020-01-01.pdf> |

---

## CI Efficiency Stats

| Metric | Value |
|---|---|
| Total workflows | 116 |
| Workflows with concurrency groups | 114 (98%) |
| Scripts using GraphQL | 33 |
| apt-get install calls | 7 |
| pip install calls | 13 |
| npm/yarn/bun install calls | 6 |

---

## Blue Angel DE-UZ 215 Checklist

| Criterion | Status | Notes |
|---|---|---|
| FOSS license | ✅ | Open source — transparency by design |
| No telemetry / tracking | ✅ | No analytics, beacons, or tracking scripts |
| No forced updates | ✅ | All updates are opt-in via OTA system |
| Runs on old hardware | ✅ | Shell scripts — no minimum spec |
| User data control | ✅ | No user data collected |
| Energy measurement | ⏳ Stub | Requires KEcoLab (GitLab) |
| Documented energy use | ⏳ Stub | Pending KEcoLab measurement |
| Green hosting | ❌ Not verified green — hosted by unknown | GitHub Pages via Azure |

---

*Full glossary: [Glossary](glossary.md) · Eco resources: [eco.kde.org](https://eco.kde.org/)*
