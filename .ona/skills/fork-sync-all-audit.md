---
name: fork-sync-all-audit
description: >
  Audit and fix fork-sync-all GitHub Actions workflows for correctness,
  consistency, and completeness. Use when asked to audit fork-sync-all,
  fix workflow bugs, review CI, check workflow triggers, or improve the
  mirror/sync infrastructure.
  Triggers on "audit fork-sync-all", "fix workflows", "workflow audit",
  "mirror chain audit", "sync workflow", "fork-sync audit".
---

# fork-sync-all Audit Skill

## Overview

`fork-sync-all` is the central infrastructure repo for `Interested-Deving-1896`.
It contains:
- **Workflows** (`.github/workflows/`) — 40+ GitHub Actions workflows for
  mirroring, syncing, README generation, token rotation, and CI hygiene
- **Scripts** (`scripts/`) — bash/python scripts called by workflows
- **Config** (`config/`) — YAML config files for template consumers, GitLab
  subgroups, overlay manifests, etc.

The repo acts as a **template** that propagates files to consumer repos via
`sync-template.sh` / `sync-template.yml`.

---

## Audit Checklist

### 1. workflow_run trigger name mismatches
The most common silent bug. `workflow_run` triggers match on the workflow's
`name:` field, not its filename.

```bash
# Find all workflow_run triggers
grep -rn 'workflow_run' .github/workflows/ | grep 'workflows:'

# Cross-check each referenced name against actual workflow name: fields
grep -rh '^name:' .github/workflows/ | sort
```
**Known instance:** `update-readmes.yml` and `translate-readmes.yml` both
referenced `"sync-from-gitlab"` but the actual workflow name is
`"Sync from GitLab"` — causing both post-GitLab-sync passes to be silently dead.

### 2. DRY_RUN / REPO_FILTER input consistency
Every workflow that iterates over repos should expose:
```yaml
inputs:
  dry_run:
    description: 'Print actions without making changes'
    type: boolean
    default: false
  repo_filter:
    description: 'Substring match on repo name (blank = all)'
    type: string
    default: ''
```
`repo_filter` must be a **substring match** (`[[ "$repo" == *"$REPO_FILTER"* ]]`),
not an exact match or regex. Check all scripts that iterate repos.

### 3. Script input propagation
Workflow env vars must be passed through to scripts. Common pattern:
```yaml
env:
  DRY_RUN: ${{ inputs.dry_run }}
  REPO_FILTER: ${{ inputs.repo_filter }}
```
Scripts read `${DRY_RUN:-false}` and `${REPO_FILTER:-}`.

### 4. Retry logic on API calls
All `curl` calls to GitHub/GitLab APIs should use `--retry 3 --retry-delay 5`.
Workflows that call scripts in a loop should have `continue-on-error: true`
on the step or handle failures gracefully.

### 5. Cron schedule stagger
Multiple workflows should not all run at `:00`. Stagger by 5–10 minutes to
avoid API rate limit collisions:
```yaml
# Good — staggered
- cron: '0 2 * * *'   # workflow A
- cron: '10 2 * * *'  # workflow B
- cron: '20 2 * * *'  # workflow C
```

### 6. Template consumer registry
`config/template-consumers.yml` lists repos that receive automatic template
updates. Check:
- All active consumer repos are listed
- Each has the correct `profile` (`full` | `mirror` | `infra-core` | `standalone`)
- `enabled: true` for repos that should receive updates
- `skip_osp_setup: true` for repos that don't participate in the OSP mirror chain

Profiles defined in `config/template-manifest.yml`:
| Profile | Contents |
|---|---|
| `full` | Everything (default) |
| `mirror` | Mirror/sync suite + infra; excludes fork-sync-all-only files |
| `infra-core` | CI hygiene only (PR automation, token rotation, branch cleanup) |
| `standalone` | Minimal: PR automation + token rotation only |

### 7. GitLab subgroup assignments
`config/gitlab-subgroups.yml` maps GitHub repos to GitLab subgroups for the
OSP mirror chain. Validate with:
```bash
python3 scripts/validate-gitlab-subgroups.py
```
The CI job `validate-config` runs this on every push.

### 8. Mirror artifact workflow inputs
`mirror-artifacts.yml` requires `source_repo` and `artifact_name` inputs.
Check that callers pass both. The workflow should fail fast if either is empty.

### 9. Token health
`token-health.yml` runs on a schedule and checks PAT expiry. Verify:
- The schedule is set (not commented out)
- `rotate-token.yml` is triggered when health check fails
- `GH_TOKEN` secret is set in the repo

---

## Template sync workflow

`sync-template.sh` has three modes:

| Mode | Trigger | What it does |
|---|---|---|
| `CREATE` | Manual | Creates new repo + pushes template + OSP setup |
| `INJECT` | Manual | Copies template into existing repos (skips existing files unless `FORCE=true`) |
| `PROPAGATE` | Push to main | Reads `template-consumers.yml`, syncs all enabled consumers |

Always-excluded paths (never overwritten in consumers):
`README.md`, `registered-imports.json`, `dep-graph/`, `.git/`, `.ona/`

Per-consumer overrides in `template-consumers.yml`:
```yaml
- name: my-repo
  profile: infra-core
  exclude_paths:
    - .github/workflows/update-readmes.yml
  include_paths:
    - .github/workflows/rotate-token.yml
  force: true
```

---

## Commit conventions

```
fix: <pass>-pass audit — <short summary>

- <workflow>: <what was wrong and what was fixed>

Co-authored-by: Ona <no-reply@ona.com>
```

Branch naming: `fix/<description>` or `feat/<description>`

---

## Anti-patterns

- Do NOT use exact string match for `REPO_FILTER` — must be substring
  (`*"$filter"*`) so partial names work
- Do NOT schedule all workflows at `:00` — stagger to avoid rate limits
- Do NOT reference workflow filenames in `workflow_run` triggers — use the
  `name:` field value
- Do NOT add repos to `template-consumers.yml` with `enabled: true` before
  verifying the repo exists and has the correct branch structure
- Do NOT set `force: true` globally in `template-consumers.yml` — it will
  overwrite repo-specific customisations on every push to main
