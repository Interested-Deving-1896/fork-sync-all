---
name: notifications-manager
description: >
  Manage GitHub notifications for the Interested-Deving-1896 org. Use when
  asked to check notifications, triage CI failures, mark notifications as read,
  snooze notifications, open notifications in browser, or run the notifications
  web UI. Triggers on "notifications", "check notifications", "triage",
  "mark read", "notification noise", "CI noise", "notification manager",
  "notify", "unread".
---

# Notifications Manager Skill

## Overview

The notifications tool is a hybrid CLI + TUI + web UI + GitHub Actions workflow
for managing GitHub notifications across the `Interested-Deving-1896` org.

**Components:**
- `scripts/notifications.sh` — CLI and TUI (fzf) interface
- `vendor/notifications-ui/index.html` — web UI (served by `--serve` mode)
- `.github/workflows/notify-manager.yml` — hourly scheduled triage + manual dispatch

**Token:** Uses `GH_TOKEN` or `SYNC_TOKEN`. Both belong to the same user and
share the same 5000 req/hr REST quota. Notification API calls are cheap (~1-3
per run).

---

## Common tasks

### Check current unread notifications

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --list
```

For JSON output (useful for piping to jq or further processing):

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --list --json
```

### Auto-triage known-safe noise

Marks as read: Mirror failures in consumer repos, btrfs-devel sync noise,
quota-exhaustion artifacts, Dependabot PRs.

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --auto-triage
```

### Interactive TUI (requires fzf)

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --tui
```

TUI keybindings:
- `ENTER` — open selected notification in browser
- `ctrl-r` — mark selected as read
- `ctrl-a` — mark all as read
- `ctrl-t` — run auto-triage
- `ESC` — quit

### Web UI

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --serve
# Opens at http://localhost:7788
```

Or via exec_preview for Ona environments:
```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --serve
```
Then use exec_preview on port 7788.

### Mark a specific notification as read

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --mark-read 12345678
```

### Mark all as read

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --mark-read
```

### Snooze a notification

```bash
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --snooze 12345678 24
# Snoozes for 24 hours (marks read now, logs wake time)
```

### Filter by type or repo

```bash
# Only CI activity
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --filter ci_activity

# Only notifications from a specific repo
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --filter-repo eggs-gui

# Combine
GH_TOKEN=$SYNC_TOKEN bash scripts/notifications.sh --filter ci_activity --filter-repo fork-sync-all
```

### Trigger the workflow manually

```bash
gh workflow run notify-manager.yml \
  --field action=auto-triage \
  --field scope=unread
```

Available actions: `auto-triage`, `list`, `mark-all-read`

---

## Known-safe auto-triage patterns

These notification title substrings are automatically marked as read by
`--auto-triage` and the scheduled workflow — they are noise, not actionable:

| Pattern | Reason |
|---|---|
| `Mirror to OpenOS-Project-OSP` | Consumer repo mirror failures — handled by mirror chain |
| `Sync btrfs-devel Branches` | Pre-existing upstream sync noise |
| `Rate limit` / `rate limit` | Quota exhaustion artifacts — self-resolving |
| `Quota` / `quota exhausted` | Same as above |
| `Dependabot` | Auto-merged dependency bumps |
| `chore(deps)` / `chore: bump` / `build(deps)` | Automated dependency PRs |

---

## Workflow: notify-manager.yml

**Schedule:** Hourly at `:17` (staggered from other workflows)
**Quota cost:** ~3-5 REST calls per run (fetch + per-notification PATCH)
**Priority tier:** 4 (LOW) — cancelled first under quota pressure

**Manual dispatch inputs:**
- `action`: `auto-triage` | `list` | `mark-all-read`
- `scope`: `unread` | `all` | `participating`
- `filter_type`: notification reason to filter (blank = all)
- `filter_repo`: repo name substring (blank = all)
- `dry_run`: report without marking read

---

## Relationship to existing notification workflows

| Workflow | Purpose |
|---|---|
| `notify-poller.yml` | Polls every 4h for CI failures → triggers `resolve-failures.yml` |
| `resolve-failures.yml` | Scans repos for failed runs, applies LLM-assisted fixes |
| `clear-notifications.yml` | Manual one-shot: mark all read |
| `notify-manager.yml` | **This tool** — hourly triage + full management interface |

`notify-manager.yml` complements `notify-poller.yml` — the poller triggers
automated fixes, the manager handles human-facing triage and noise reduction.

---

## Quota impact

Notification API calls do **not** use ETag caching in the manager (unlike the
poller). Each hourly run costs:
- 1 call: fetch notifications list
- N calls: PATCH per triaged notification (typically 0-10)

With `MIN_QUOTA: 200`, the workflow skips entirely when quota is low.

---

## Anti-patterns

- Do NOT call `--mark-read` (all) during active debugging sessions — you'll
  lose context on what's failing.
- Do NOT add new auto-triage patterns without verifying they're genuinely
  non-actionable. Check `resolve-failures.sh` to confirm the pattern is
  already handled there.
- The `--serve` web UI proxies all API calls through Python — do not expose
  port 7788 publicly (no auth on the proxy).
