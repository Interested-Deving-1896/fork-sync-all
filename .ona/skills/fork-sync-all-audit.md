---
name: fork-sync-all-audit
description: >
  Audit and fix fork-sync-all GitHub Actions workflows, scripts, and config
  for correctness, consistency, and completeness. Use when asked to audit
  fork-sync-all, fix workflow bugs, review CI, check workflow triggers,
  improve the mirror/sync infrastructure, or work on arch repo creation.
  Triggers on "audit fork-sync-all", "fix workflows", "workflow audit",
  "mirror chain audit", "sync workflow", "fork-sync audit", "arch repos",
  "kernel repos", "patchset branches".
---

# fork-sync-all Audit Skill

## Overview

`fork-sync-all` is the template source and sync orchestrator for a three-org
GitHub mirror chain:

```
Interested-Deving-1896  ──►  OpenOS-Project-OSP  ──►  OpenOS-Project-Ecosystem-OOC
        ▲                                                         │
        └─────────── upstream-commits / upstream-prs ────────────┘
```

Key directories:
- `.github/workflows/` — 40+ GitHub Actions workflows
- `scripts/` — bash/python scripts called by workflows
- `config/` — YAML config for template consumers, GitLab subgroups, manifests
- `.ona/skills/` — Ona agent skills for this repo and KPort
- `AGENTS.md` — agent guidance (propagates to all mirror/infra-core consumers)
- `AGENTS-IMPROVEMENT-SPEC.md` — working defect tracker (propagates to consumers)

Always read `AGENTS.md` first — it has the rate limit patterns, template
propagation rules, arch repo structure, and commit conventions.

---

## Before starting any audit

```bash
# 1. Check rate limit — all bulk operations need this
gh api rate_limit --jq '.resources.core | "remaining: \(.remaining)/\(.limit)  resets: \(.reset | todate)"'

# 2. Run validators — must pass before and after any changes
python3 -m pytest tests/ -v
python3 scripts/validate-template-config.py
python3 scripts/validate-registered-imports.py
python3 scripts/validate-workflow-guards.py

# 3. Check all workflow_run trigger names match actual workflow name: fields
python3 - <<'EOF'
import re, glob
actual = {}
for f in glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"):
    with open(f) as fh:
        for line in fh:
            m = re.match(r'^name:\s*(.+)', line)
            if m: actual[m.group(1).strip()] = f; break
for tf in sorted(glob.glob(".github/workflows/*.yml")):
    with open(tf) as fh: content = fh.read()
    in_block = False
    for line in content.splitlines():
        if 'workflow_run:' in line: in_block = True
        if in_block and 'types:' in line: in_block = False
        if in_block:
            m = re.search(r'- "([^"]+)"', line)
            if m and m.group(1) not in actual:
                print(f"BROKEN: {tf}: \"{m.group(1)}\"")
EOF
```

---

## Audit checklist

### 1. `workflow_run` trigger name mismatches

GitHub matches `workflow_run` on the `name:` field, not the filename.
The check above finds all broken references. As of 2026-05-27 all references
are verified clean — run the check again after any workflow rename.

### 2. `DRY_RUN` / `REPO_FILTER` input consistency

All 12 bulk-mutation scripts correctly declare and gate on these vars.
Pattern to verify:

```bash
for s in scripts/*.sh; do
  dry=$(grep -c 'DRY_RUN="\${DRY_RUN' "$s" 2>/dev/null || echo 0)
  gate=$(grep -c 'DRY_RUN.*==.*true' "$s" 2>/dev/null || echo 0)
  [[ "$dry" -eq 0 ]] && echo "MISSING DRY_RUN decl: $s"
  [[ "$dry" -gt 0 && "$gate" -eq 0 ]] && echo "MISSING DRY_RUN gate: $s"
done
```

### 3. Retry logic on API calls

All `api_get` / `gh_get` functions must retry on 403/429. Reference pattern
from `scripts/create-arch-repos.py` `gh_api()`. Scripts verified clean as of
2026-05-27: `cleanup-branches.sh`, `upstream-prs.sh`,
`sync-btrfs-devel-branches.sh`, `mirror-releases.sh`, `mirror-orgs.sh`.

Quick check:
```bash
for s in scripts/*.sh; do
  curl_bare=$(grep -cE 'curl.*--fail[^-]|curl -sf ' "$s" 2>/dev/null || echo 0)
  [[ "$curl_bare" -gt 0 ]] && echo "BARE CURL (no retry): $s ($curl_bare sites)"
done
```

### 4. Template consumer registry

`config/template-consumers.yml` lists repos that receive automatic template
updates. Profiles defined in `config/template-manifest.yml`:

| Profile | Contents |
|---|---|
| `full` | Everything |
| `mirror` | Mirror/sync suite + infra; excludes fork-sync-all-only files |
| `infra-core` | CI hygiene only (PR automation, token rotation, branch cleanup) |
| `standalone` | Minimal: PR automation + token rotation only |

Always-excluded paths (never written to consumers) — defined in
`scripts/sync-template.sh` `EXCLUDED_PATHS`:
`README.md`, `registered-imports.json`, `dep-graph/`, `.git/`, `.ona/`,
`DOCS/`, `tests/`, `scripts/validate-*.py`, fork-sync-all-specific workflows.

`AGENTS.md` and `AGENTS-IMPROVEMENT-SPEC.md` **are** propagated to
`mirror` and `infra-core` consumers.

### 5. Cron schedule stagger

Verified clean as of 2026-05-27 — no two heavy workflows share the same
minute slot. Current schedule:

| Slot | Workflow |
|---|---|
| `:00` | `mirror-releases.yml` |
| `:10` | `mirror-artifacts.yml` |
| `:30` | `mirror-osp-to-gitlab.yml`, `upstream-prs.yml` |
| `:45` | `setup-osp-mirrors.yml` |
| `:47` | `upstream-commits.yml` |
| `:55` | `sync-registered-imports.yml` |
| Daily `05:50` | `reconcile-org-refs.yml` |

### 6. GitLab subgroup assignments

`config/gitlab-subgroups.yml` maps GitHub repos to GitLab subgroups.
Validate with:
```bash
python3 scripts/validate-gitlab-subgroups.py
```

### 7. `mirror-to-osp.sh` default branch gate

Fixed 2026-05-27 — uses `default_branch` from repo metadata instead of
hardcoded `main`. Repos with `master` default branch (e.g. `penguins-eggs`)
are no longer silently skipped.

### 8. Token expiry (time-sensitive)

From `scripts/token-monitor.sh` — rotate before these dates:
- `OSP-ORG Mirror Token` — **2026-06-28**
- `sync-mirror-watchdog` — **2026-07-03**

---

## Arch repo infrastructure

10 CPU architectures × 35 repos each = 350 repos total across 3 tiers.
See `AGENTS.md` for the full breakdown and creation commands.

Scripts:
- `scripts/create-arch-repos.py` — creates repos for one or more archs
- `scripts/run-tier1-arm64.sh` / `run-tier2.sh` / `run-tier3.sh` — tier runners
- `scripts/run-all-tiers.sh` — full orchestration with rate limit handling
- `scripts/push-kernel-content.sh` — pushes Linux v6.9 to kernel-base repos
- `scripts/seed-patchset-branches.sh` — seeds 270 patchset branches

Kernel clone at `/workspaces/linux-kernel` (v6.9, 1.8GB).

---

## Commit conventions

```
fix: <short summary>

- <file>: <what was wrong and what was fixed>

Co-authored-by: Ona <no-reply@ona.com>
```

Branch naming: `fix/<description>` or `feat/<description>`

---

## Anti-patterns

- Do NOT reference workflow filenames in `workflow_run` triggers — use the
  `name:` field value
- Do NOT use exact string match for `REPO_FILTER` — must be substring
  (`*"$filter"*`) so partial names work
- Do NOT schedule two heavy workflows at the same minute slot
- Do NOT add repos to `template-consumers.yml` with `enabled: true` before
  verifying the repo exists and has the correct branch structure
- Do NOT set `force: true` globally in `template-consumers.yml` — overwrites
  repo-specific customisations on every push to main
- Do NOT run arch repo creation without checking rate limit first —
  350 repos × ~3 API calls each = ~1050 calls minimum
- Do NOT push to kernel-base repos before the kernel clone at
  `/workspaces/linux-kernel` is complete
