#!/usr/bin/env python3
"""
Regenerates docs/workflow-triggers.md and docs/workflow-triggers.txt
by parsing all workflow files in .github/workflows/.

Groups are defined in GROUPS below. Any workflow not matched by a group
is appended to the "Utility / On-Demand" section automatically.

Usage:
    python3 scripts/generate-workflow-triggers-doc.py [repo-root]
"""

import glob
import os
import re
import shutil
import sys
from datetime import datetime, timezone

import yaml

REPO_URL = "https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/.github/workflows"
ACTIONS_URL = "https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows"
COSTS_CONFIG = "config/workflow-quota-costs.yml"

# ── Group definitions ─────────────────────────────────────────────────────────
# Each group has a display name and a list of filename substrings that belong
# to it. Order matters — first match wins.
GROUPS = [
    ("Accessibility", [
        "check-accessibility",
    ]),
    ("AI & Cost Tracking", [
        "track-agent-costs", "sync-agent-prices",
        "eco-audit", "opencode",
    ]),
    ("BDFS / Filesystem Workspace", [
        "bdfs-dev", "bdfs-dev-btrfs", "bdfs-dev-dwarfs",
        "bdfs-dev-overlay", "bdfs-package",
    ]),
    ("Bugzilla Integration", [
        "onboard-bugzilla", "sync-to-bugzilla",
        "bugzilla-failure-report", "bugzilla-milestone-ship",
    ]),
    ("Build & Release", [
        "build", "build-x86", "build-arm64", "build-selfhosted",
        "checks", "release", "dwarfs-pack-caller",
        "push-kernel-content", "seed-patchset-branches", "gen-arch-config",
    ]),
    ("CI & Failure Resolution", [
        "resolve-failures", "notify-poller", "rate-limit-rerun",
        "rebase-lts", "rate-limit-status",
        "notify-manager", "runner-status",
    ]),
    ("Documentation & Publishing", [
        "deploy-book", "generate-book-pages", "update-book-index",
        "book-export", "gitbook-oss", "translate-docs",
        "generate-notebooklm", "refresh-notebooklm",
        "update-workflow-triggers-doc",
        "generate-repo-descriptions", "upload-notebooklm",
    ]),
    ("Fork & Import Sync", [
        "sync-forks", "sync-pieroproietti", "sync-registered-imports",
        "import-repo", "sync-upstream-sources", "sync-btrfs",
        "sync-registry-sources", "upstream-prs", "upstream-commits",
        "btrfs-devel-sync", "sync-fsa-forks", "sync-in",
        "sync-kde-groups-mirrors", "sync-kde-neon-mirrors",
        "sync-ona-projects", "sync-registry-backend",
        "sync-shell-tools", "sync-uaa-vendor", "sync-upstream-mirrors",
        "upstream-contribute-caller", "upstream-workflow-proposal",
        "integrate-shell-tools",
    ]),
    ("Full Pipeline", [
        "flush-lifecycle",
        "pre-flush-prep",
        "full-chain-flush",
        "post-flush-prep",
        "critical-deploy",
        "flush-active-watchdog",
        "pipeline-telemetry",
        "bootstrap-triggers",
    ]),
    ("Git Platform Sync", [
        # Canonical bidirectional platform sync (supersedes sync-to-gitlab + sync-from-gitlab)
        "git-platform-sync", "sync-to-gitlab-variant",
        "check-gitlab-sync",
        # Deprecated stubs — kept for reference, flagged for deletion
        "sync-to-gitlab", "sync-from-gitlab",
    ]),
    ("Infrastructure & Environment", [
        "devcontainer-sdk", "docker-to-incus", "test-time-format",
        "fsa-api",
    ]),
    ("Maintenance & Housekeeping", [
        "reconcile-org-refs", "reconcile-identity-assets",
        "cleanup-branches", "cleanup-pollution",
        "sync-template", "update-infra-deps",
        "generate-dep-graph", "token-health", "rotate-token",
        "validate-config", "cancel-post-rotation",
        "branch-hygiene-report", "manage-subtrees",
        "org-storage-maintenance", "pin-manager",
        "update-kde-builder-vendor",
    ]),
    ("Mirror Chain", [
        # Core push chain: source → OSP → OOC → GitLab
        "mirror-to-osp", "mirror-osp-to-ooc", "mirror-osp-to-gitlab",
        "mirror-orgs", "mirror-releases", "mirror-artifacts",
        "mirror-orgs-watchdog",
        # Dispatcher and integrity layer
        "mirror-chain-dispatch", "verify-fork-integrity", "verify-mirror-integrity",
        # Package/image mirrors
        "mirror-flatpak", "mirror-ghcr", "mirror-pypi", "mirror-rpm",
        # Consumer-repo push template
        "mirror.yaml",
    ]),
    ("OSP-Bound Repo Management", [
        "add-mirror-repo", "check-osp-ci", "setup-osp-mirrors",
        "create-ooc-subgroups", "delete-stale-repos",
        "manage-repo-settings", "onboard-repo", "provision-maintenance",
    ]),
    ("OTA System", [
        "ota-release", "ota-reconcile", "ota-self-update",
        "ota-discover", "ota-opt-in",
    ]),
    ("PR Governance & Trust", [
        "vouch-check-pr", "vouch-manage", "vouch-sync-codeowners",
        "pr-gate", "pr-lifecycle-guard", "labeler",
        "a11y-pr-gate", "pr-automation",
        "auto-merge-prs", "merge-ready-prs", "rebase-prs",
    ]),
    ("Quota & Queue Management", [
        "quota-reserve", "queue-manager", "quota-monitor",
        "update-quota-costs", "list-active-runs",
    ]),
    ("README Management", [
        "update-readmes", "create-readmes", "translate-readmes",
        "lts-readmes", "validate-readme-render", "readme-wizard",
        "inject-badges", "patch-origins",
        "inject-motto", "trigger-readme-update",
    ]),
    ("Security & Compliance", [
        "generate-sbom", "codeql-analysis", "enforce-agnostic-vendor",
        "full-audit", "audit-arch-repos", "pin-workflows",
    ]),
    ("Utility / On-Demand", [
        "cancel-stale-runs", "clone-org",
        "fork-neon-repos", "merge-to-monorepo", "repo-manifest",
        "sync-eggs-docs", "shallow-reclone", "gl-storage-scan",
        "list-chromium", "setup-gitlab-schedules", "trigger-artifact",
        "ci", "clear-notifications", "setup-dashboard-vars",
        "upload-asset",
    ]),
]

# ── Explicit sort order for groups where alphabetical is wrong ────────────────
# Maps group name → list of filename substrings in the desired display order.
# Workflows not listed here sort alphabetically after the pinned ones.
# Add a new entry here whenever a group has a natural execution/dependency order
# that differs from alphabetical — no changes to the rendering logic needed.
GROUP_SORT_KEYS: dict[str, list[str]] = {
    # Outward mirror chain: source → OSP → OOC → GitLab, then dispatcher, integrity, packages, template
    "Mirror Chain": [
        "mirror-to-osp",
        "mirror-osp-to-ooc",
        "mirror-osp-to-gitlab",
        "mirror-orgs",
        "mirror-releases",
        "mirror-artifacts",
        "mirror-orgs-watchdog",
        "mirror-chain-dispatch",
        "verify-fork-integrity",
        "verify-mirror-integrity",
        "mirror-flatpak",
        "mirror-ghcr",
        "mirror-pypi",
        "mirror-rpm",
        "mirror.yaml",
    ],

    # PR governance: trust gate → manage → sync → PR gate → lifecycle → label → a11y → automation → merge
    "PR Governance & Trust": [
        "vouch-check-pr",
        "vouch-manage",
        "vouch-sync-codeowners",
        "pr-gate",
        "pr-lifecycle-guard",
        "labeler",
        "a11y-pr-gate",
        "pr-automation",
        "auto-merge-prs",
        "merge-ready-prs",
        "rebase-prs",
    ],
    # CI flow: detection → rerun → resolution → status checks → notifications → runner health
    "CI & Failure Resolution": [
        "rate-limit-rerun",
        "notify-poller",
        "resolve-failures",
        "rebase-lts",
        "rate-limit-status",
        "notify-manager",
        "runner-status",
    ],
    # Bugzilla: onboard → sync commits → file failures → ship milestones
    "Bugzilla Integration": [
        "onboard-bugzilla",
        "sync-to-bugzilla",
        "bugzilla-failure-report",
        "bugzilla-milestone-ship",
    ],
    # Build: generic → arch-specific → self-hosted → checks → release → pack → kernel
    "Build & Release": [
        "build",
        "build-x86",
        "build-arm64",
        "build-selfhosted",
        "checks",
        "release",
        "dwarfs-pack-caller",
        "push-kernel-content",
        "seed-patchset-branches",
        "gen-arch-config",
    ],
    # BDFS: workspace → backends → package
    "BDFS / Filesystem Workspace": [
        "bdfs-dev",
        "bdfs-dev-btrfs",
        "bdfs-dev-dwarfs",
        "bdfs-dev-overlay",
        "bdfs-package",
    ],
    # Maintenance: validate first, then reconcile, cleanup, sync, generate/update, housekeeping
    "Maintenance & Housekeeping": [
        "validate-config",
        "reconcile-org-refs",
        "reconcile-identity-assets",
        "cleanup-branches",
        "cleanup-pollution",
        "sync-template",
        "update-infra-deps",
        "generate-dep-graph",
        "token-health",
        "rotate-token",
        "cancel-post-rotation",
        "branch-hygiene-report",
        "manage-subtrees",
        "org-storage-maintenance",
        "pin-manager",
        "update-kde-builder-vendor",
    ],
    # Full pipeline: orchestrator → prep → flush → verify → emergency fast-lane → watchdog → telemetry → bootstrap
    "Full Pipeline": [
        "flush-lifecycle",
        "pre-flush-prep",
        "full-chain-flush",
        "post-flush-prep",
        "critical-deploy",
        "flush-active-watchdog",
        "pipeline-telemetry",
        "bootstrap-triggers",
    ],
    # Quota: reserve (enforcement) → queue (dedup) → monitor (health) → costs (observability) → visibility
    "Quota & Queue Management": [
        "quota-reserve",
        "queue-manager",
        "quota-monitor",
        "update-quota-costs",
        "list-active-runs",
    ],
    # OTA: release (push delivery) → reconcile (fallback) → self-update (pull) → discover → opt-in
    "OTA System": [
        "ota-release",
        "ota-reconcile",
        "ota-self-update",
        "ota-discover",
        "ota-opt-in",
    ],
}
# Groups not in GROUP_SORT_KEYS (Accessibility, Documentation & Publishing,
# README Management, Security & Compliance, etc.) sort alphabetically by
# workflow name — no pipeline dependency order justifies a custom sequence.

# ── Cron → human-readable ─────────────────────────────────────────────────────
def cron_to_parts(cron: str) -> tuple[str, str]:
    """Return (frequency, time) for a cron expression.

    frequency — how often: Daily, Weekly, Monthly, Every Nh, Every N min
    time      — when: HH:MM, day-of-week, day-of-month, or :MM for sub-hourly
    """
    parts = cron.strip().split()
    if len(parts) != 5:
        return ("", cron)

    minute, hour, dom, month, dow = parts

    # Every N minutes  e.g. */15 * * * *
    if re.match(r'^\*/\d+$', minute) and hour == "*" and dom == "*" and month == "*" and dow == "*":
        n = minute.split("/")[1]
        return (f"Every {n} min", "")

    # Every N hours  e.g. 10 */4 * * *
    if re.match(r'^\*/\d+$', hour) and dom == "*" and month == "*" and dow == "*":
        n = hour.split("/")[1]
        try:
            m = int(minute)
            return (f"Every {n}h", f"at :{m:02d}")
        except ValueError:
            pass

    # Monthly  e.g. 0 5 1 * *
    if dom != "*" and month == "*" and dow == "*":
        try:
            d = int(dom)
            suffix = {1: "st", 2: "nd", 3: "rd"}.get(d if d < 20 else d % 10, "th")
            h, m = int(hour), int(minute)
            return ("Monthly", f"{d}{suffix} {h:02d}:{m:02d}")
        except ValueError:
            pass

    # Weekly  e.g. 0 9 * * 1
    if dow != "*" and dom == "*":
        days = {"0": "Sun", "1": "Mon", "2": "Tue", "3": "Wed",
                "4": "Thu", "5": "Fri", "6": "Sat", "7": "Sun"}
        day_name = days.get(dow, dow)
        try:
            h, m = int(hour), int(minute)
            return ("Weekly", f"{day_name} {h:02d}:{m:02d}")
        except ValueError:
            pass

    # Daily  e.g. 30 7 * * *
    if hour != "*" and re.match(r'^\d+$', hour) and dom == "*" and month == "*" and dow == "*":
        try:
            h, m = int(hour), int(minute)
            return ("Daily", f"{h:02d}:{m:02d}")
        except ValueError:
            pass

    return ("", cron)


def cron_to_human(cron: str) -> str:
    """Convert a cron expression to a single human-readable string (legacy)."""
    freq, time = cron_to_parts(cron)
    if not freq:
        return cron
    if not time:
        return freq
    return f"{freq} {time}"


# ── Parse a single workflow file ──────────────────────────────────────────────
def parse_workflow(path: str) -> dict:
    try:
        data = yaml.safe_load(open(path))
    except Exception:
        return {}
    if not data:
        return {}

    on = data.get(True) or data.get("on") or {}
    if not isinstance(on, dict):
        return {}

    fname = os.path.basename(path)
    name  = data.get("name", fname)

    schedules    = []
    push_paths   = []
    pr           = False
    dispatch     = False
    workflow_run = []

    if "schedule" in on:
        for s in (on["schedule"] or []):
            c = s.get("cron", "")
            if c:
                schedules.append(c)

    if "push" in on:
        push = on["push"] or {}
        paths = push.get("paths", []) if isinstance(push, dict) else []
        push_paths = paths if paths else ["(any)"]

    if "pull_request" in on:
        pr = True

    if "workflow_dispatch" in on:
        dispatch = True

    if "workflow_run" in on:
        wr = on["workflow_run"] or {}
        workflow_run = wr.get("workflows", []) if isinstance(wr, dict) else []

    return {
        "file":         fname,
        "name":         name,
        "schedules":    schedules,
        "push_paths":   push_paths,
        "pr":           pr,
        "dispatch":     dispatch,
        "workflow_run": workflow_run,
    }


# ── Assign workflow to a group ────────────────────────────────────────────────
def assign_group(fname: str) -> str:
    for group_name, patterns in GROUPS:
        for pat in patterns:
            if pat in fname:
                return group_name
    return "Utility / On-Demand"


# ── Format triggers for Markdown table cell ───────────────────────────────────
def md_also_triggers(wf: dict) -> str:
    parts = []
    if wf["push_paths"]:
        paths = ", ".join(f"`{p}`" for p in wf["push_paths"][:3])
        suffix = f" (+{len(wf['push_paths'])-3} more)" if len(wf["push_paths"]) > 3 else ""
        parts.append(f"push to {paths}{suffix}")
    if wf["pr"]:
        parts.append("pull_request")
    if wf["workflow_run"]:
        for upstream in wf["workflow_run"]:
            parts.append(f"`{upstream}` completes")
    if wf["dispatch"]:
        parts.append("dispatch")
    return " · ".join(parts) if parts else "—"


def md_schedule(wf: dict) -> str:
    if not wf["schedules"]:
        return "—"
    return " · ".join(cron_to_human(c) for c in wf["schedules"])


# ── Generate Markdown ─────────────────────────────────────────────────────────
def generate_md(grouped: dict, all_wfs: list, now: str, synopses: dict = None) -> str:
    synopses = synopses or {}
    lines = []
    lines.append("# Workflow Triggers")
    lines.append("")
    lines.append("All workflows in `.github/workflows/`. Grouped by function, with every trigger listed.")
    lines.append("")
    lines.append("> Plain-text version: [`docs/workflow-triggers.txt`](workflow-triggers.txt)  ")
    lines.append(f"> Auto-generated on {now} from `.github/workflows/` and `config/workflow-quota-costs.yml`")
    lines.append("")

    for group_name, _ in GROUPS:
        wfs = grouped.get(group_name, [])
        if not wfs:
            continue

        # Apply explicit ordering for groups where alphabetical is wrong
        if group_name in GROUP_SORT_KEYS:
            order = GROUP_SORT_KEYS[group_name]
            def _sort_key(wf, _order=order):
                for i, pat in enumerate(_order):
                    if pat in wf["file"]:
                        return (i, wf["name"])
                return (len(_order), wf["name"])
            wfs = sorted(wfs, key=_sort_key)

        lines.append(f"---")
        lines.append("")
        lines.append(f"## {group_name}")
        lines.append("")

        # Utility section has no schedule column
        if group_name == "Utility / On-Demand":
            lines.append("| Workflow | Synopsis | File | Trigger |")
            lines.append("|---|---|---|---|")
            for wf in wfs:
                trigger   = md_also_triggers(wf)
                file_link = f"[↗]({REPO_URL}/{wf['file']})"
                run_link  = f"[▶ Run]({ACTIONS_URL}/{wf['file']})"
                synopsis  = synopses.get(wf['name'], "")
                lines.append(f"| {wf['name']} {file_link} {run_link} | {synopsis} | `{wf['file']}` | {trigger} |")
        else:
            lines.append("| Workflow | Synopsis | File | Schedule | Also triggers on |")
            lines.append("|---|---|---|---|---|")
            for wf in wfs:
                sched     = md_schedule(wf)
                also      = md_also_triggers(wf)
                file_link = f"[↗]({REPO_URL}/{wf['file']})"
                run_link  = f"[▶ Run]({ACTIONS_URL}/{wf['file']})"
                synopsis  = synopses.get(wf['name'], "")
                lines.append(f"| {wf['name']} {file_link} {run_link} | {synopsis} | `{wf['file']}` | {sched} | {also} |")
        lines.append("")

    # Schedule summary
    lines.append("---")
    lines.append("")
    lines.append("## Schedule Summary (UTC)")
    lines.append("")
    lines.append("| Time | Frequency | Workflow |")
    lines.append("|---|---|---|")

    schedule_rows = []
    for wf in all_wfs:
        for cron in wf["schedules"]:
            freq, time = cron_to_parts(cron)
            schedule_rows.append((cron, freq, time, wf["name"]))

    # Sort by cron minute then hour
    def sort_key(row):
        parts = row[0].strip().split()
        if len(parts) != 5:
            return (99, 99, row[3])
        minute, hour = parts[0], parts[1]
        try:
            m = int(minute)
        except ValueError:
            m = 99
        try:
            h = int(hour.split("/")[-1]) if "/" in hour else int(hour.replace("*", "99"))
        except ValueError:
            h = 99
        return (h, m, row[3])

    # Build a name→file lookup for schedule summary links
    name_to_file = {wf["name"]: wf["file"] for wf in all_wfs}

    for _, freq, time, name in sorted(schedule_rows, key=sort_key):
        fname = name_to_file.get(name, "")
        links = f" [↗]({REPO_URL}/{fname}) [▶ Run]({ACTIONS_URL}/{fname})" if fname else ""
        lines.append(f"| {time} | {freq} | {name}{links} |")

    lines.append("")
    return "\n".join(lines)


# ── Generate plain text ───────────────────────────────────────────────────────
def generate_txt(grouped: dict, all_wfs: list, now: str, synopses: dict = None) -> str:
    synopses = synopses or {}
    lines = []
    lines.append("FORK-SYNC-ALL — WORKFLOW TRIGGERS")
    lines.append("===================================")
    lines.append("Generated from .github/workflows/ and config/workflow-quota-costs.yml")
    lines.append(f"Last updated: {now}")
    lines.append("")
    lines.append("Legend")
    lines.append("------")
    lines.append("  schedule       Runs automatically on a cron schedule (UTC)")
    lines.append("  push           Runs when matching files are pushed to main")
    lines.append("  pull_request   Runs when a PR is opened or updated")
    lines.append("  workflow_run   Runs automatically after another workflow completes")
    lines.append("  dispatch       Manual trigger only (workflow_dispatch)")
    lines.append("")

    for group_name, _ in GROUPS:
        wfs = grouped.get(group_name, [])
        if not wfs:
            continue

        # Apply explicit ordering for groups where alphabetical is wrong
        if group_name in GROUP_SORT_KEYS:
            order = GROUP_SORT_KEYS[group_name]
            def _sort_key(wf, _order=order):
                for i, pat in enumerate(_order):
                    if pat in wf["file"]:
                        return (i, wf["name"])
                return (len(_order), wf["name"])
            wfs = sorted(wfs, key=_sort_key)

        lines.append("")
        lines.append(group_name.upper())
        lines.append("-" * len(group_name))
        lines.append("")
        for wf in wfs:
            lines.append(f"{wf['name']}  ({wf['file']})")
            synopsis = synopses.get(wf['name'], "")
            if synopsis:
                # Wrap at 80 chars with 2-space indent
                import textwrap
                wrapped = textwrap.fill(synopsis, width=78, initial_indent="  ", subsequent_indent="  ")
                lines.append(wrapped)
            for cron in wf["schedules"]:
                lines.append(f"  schedule   {cron_to_human(cron)}  ({cron})")
            for path in wf["push_paths"]:
                lines.append(f"  push       {path}")
            if wf["pr"]:
                lines.append("  pull_request")
            for upstream in wf["workflow_run"]:
                lines.append(f"  workflow_run  {upstream}")
            if wf["dispatch"]:
                lines.append("  dispatch")
            lines.append("")

    lines.append("")
    lines.append("SCHEDULE SUMMARY (UTC)")
    lines.append("----------------------")
    lines.append("")
    for wf in sorted(all_wfs, key=lambda w: w["schedules"][0] if w["schedules"] else "zzz"):
        for cron in wf["schedules"]:
            lines.append(f"{cron_to_human(cron):<30} {wf['name']}")

    lines.append("")
    return "\n".join(lines)


# ── Load synopses from workflow-quota-costs.yml ───────────────────────────────
def load_synopses(repo_root: str) -> dict:
    """Return {workflow_name: synopsis} from config/workflow-quota-costs.yml."""
    costs_path = os.path.join(repo_root, COSTS_CONFIG)
    if not os.path.exists(costs_path):
        return {}
    try:
        with open(costs_path) as f:
            data = yaml.safe_load(f) or {}
        return {
            wf["name"]: wf["synopsis"]
            for wf in (data.get("workflows") or [])
            if wf.get("name") and wf.get("synopsis")
        }
    except Exception:
        return {}


# ── Collect live counts from config files ────────────────────────────────────

def collect_counts(repo_root: str, wf_count: int) -> dict:
    """Return a dict of live counts read from config files."""
    import json as _json

    counts = {"workflows": wf_count}

    # Registered imports
    try:
        imports_path = os.path.join(repo_root, "registered-imports.json")
        with open(imports_path) as f:
            counts["registered_imports"] = len(_json.load(f))
    except Exception:
        counts["registered_imports"] = None

    # GitLab subgroups + mirrored repos
    try:
        sg_path = os.path.join(repo_root, "config", "gitlab-subgroups.yml")
        with open(sg_path) as f:
            sg_data = yaml.safe_load(f) or {}
        subgroups = sg_data.get("subgroups", {})
        counts["gitlab_subgroups"] = len(subgroups)
        counts["gitlab_repos"] = sum(
            len(v.get("repos", [])) for v in subgroups.values() if isinstance(v, dict)
        )
    except Exception:
        counts["gitlab_subgroups"] = None
        counts["gitlab_repos"] = None

    # Template consumers (non-disabled)
    try:
        tc_path = os.path.join(repo_root, "config", "template-consumers.yml")
        with open(tc_path) as f:
            tc_data = yaml.safe_load(f) or {}
        consumers = [c for c in (tc_data.get("consumers") or []) if not c.get("disabled")]
        counts["template_consumers"] = len(consumers)
    except Exception:
        counts["template_consumers"] = None

    return counts


# ── Update README.md FSA-GROUPS block ────────────────────────────────────────

# Short descriptions for each group shown in the README table.
GROUP_DESCRIPTIONS: dict[str, str] = {
    "Accessibility":               "CODEOWNERS coverage, screen-reader scan, WCAG audit, audio overview, Braille output",
    "AI & Cost Tracking":          "Session cost log, weekly price sync",
    "BDFS / Filesystem Workspace": "DwarFS/BTRFS workspace dev and packaging",
    "Bugzilla Integration":        "Sync commits/PRs to Bugzilla, milestone shipping",
    "Build & Release":             "Build, checks, release, kernel content, arch config",
    "CI & Failure Resolution":     "Rate-limit rerun, failure resolver, runner status",
    "Documentation & Publishing":  "mdBook, GitBook, NotebookLM, translate docs, triggers doc",
    "Fork & Import Sync":          "Upstream fork sync, registered imports, platform import",
    "Full Pipeline":               "pre-flush → full-chain-flush → post-flush + critical-deploy",
    "Git Platform Sync":           "Bidirectional push/pull sync with GitLab",
    "Infrastructure & Environment":"Dev container SDK, Incus, FSA API",
    "Maintenance & Housekeeping":  "Config validation, cleanup, token rotation, dep updates",
    "Mirror Chain":                "Outward mirror: I-D-1896 → OSP → OOC → GitLab",
    "OSP-Bound Repo Management":   "Add mirror repo, CI status, setup OSP mirrors",
    "OTA System":                  "Release delivery, reconcile, self-update, discover, opt-in",
    "PR Governance & Trust":       "Vouch, PR gate, labeler, auto-merge, rebase",
    "Quota & Queue Management":    "Reserve, dedup, monitor, cost registry",
    "README Management":           "Create, update, badge, translate, validate READMEs",
    "Security & Compliance":       "SBOM, CodeQL, vendor audit, arch audit, pin workflows",
    "Utility / On-Demand":         "Manual and specialised workflows",
}


def update_readme_groups(repo_root: str, all_wfs: list, now: str) -> bool:
    """
    Replace the <!-- FSA-GROUPS-START --> … <!-- FSA-GROUPS-END --> block in
    README.md with a freshly generated alphabetical groups table.
    """
    readme_path = os.path.join(repo_root, "README.md")
    if not os.path.exists(readme_path):
        return False

    with open(readme_path) as f:
        original = f.read()

    pattern = r"<!-- FSA-GROUPS-START[^>]*-->.*?<!-- FSA-GROUPS-END -->"
    if not re.search(pattern, original, re.DOTALL):
        return False

    # Count workflows per group (same logic as collect_counts)
    wf_names = {os.path.splitext(os.path.basename(w.get("file", "")))[0] for w in all_wfs}
    group_counts: dict[str, int] = {}
    assigned: set[str] = set()
    for group_name, patterns in GROUPS:
        count = 0
        for pat in patterns:
            stem = os.path.splitext(pat)[0]
            if stem in wf_names and stem not in assigned:
                count += 1
                assigned.add(stem)
        group_counts[group_name] = count

    total = sum(group_counts.values())
    n_groups = len(GROUPS)

    rows = []
    for group_name, _ in GROUPS:  # GROUPS is already alphabetical
        count = group_counts.get(group_name, 0)
        desc = GROUP_DESCRIPTIONS.get(group_name, "")
        # GitHub markdown anchor algorithm: lowercase, spaces→hyphens, then strip
        # all non-alphanumeric-hyphen chars. Punctuation like & and / is removed
        # after spaces are already hyphens, leaving "--" around them.
        anchor = group_name.lower()
        anchor = re.sub(r"\s", "-", anchor)           # spaces → hyphens first
        anchor = re.sub(r"[^a-z0-9-]", "", anchor)   # strip &, /, etc.
        anchor = re.sub(r"-{3,}", "--", anchor)       # collapse 3+ dashes to 2
        link = f"[{group_name}](DOCS/workflow-triggers.md#{anchor})"
        rows.append(f"| {link} | {count} | {desc} |")

    block_lines = [
        f"<!-- FSA-GROUPS-START — updated {now} by generate-workflow-triggers-doc.py -->",
        f"{total} workflows across {n_groups} functional groups. Full detail in [DOCS/workflow-triggers.md](DOCS/workflow-triggers.md).",
        f"",
        f"| Group | Workflows | Description |",
        f"|---|---|---|",
    ] + rows + [
        f"<!-- FSA-GROUPS-END -->",
    ]
    new_block = "\n".join(block_lines)

    updated = re.sub(pattern, new_block, original, flags=re.DOTALL)
    if updated == original:
        return False

    with open(readme_path, "w") as f:
        f.write(updated)
    return True


# ── Update README.md FSA-COUNTS block ────────────────────────────────────────

def update_readme_counts(repo_root: str, counts: dict, now: str) -> bool:
    """
    Replace the <!-- FSA-COUNTS-START --> … <!-- FSA-COUNTS-END --> block in
    README.md with freshly computed counts. Returns True if the file changed.
    """
    readme_path = os.path.join(repo_root, "README.md")
    if not os.path.exists(readme_path):
        return False

    with open(readme_path) as f:
        original = f.read()

    def _fmt(v):
        return str(v) if v is not None else "—"

    block_lines = [
        f"<!-- FSA-COUNTS-START — updated {now} by generate-workflow-triggers-doc.py -->",
        f"| | |",
        f"|---|---|",
        f"| Workflows | **{_fmt(counts['workflows'])}** |",
        f"| Registered imports | **{_fmt(counts['registered_imports'])}** |",
        f"| Template consumers | **{_fmt(counts['template_consumers'])}** |",
        f"| GitLab subgroups | **{_fmt(counts['gitlab_subgroups'])}** |",
        f"| GitLab repos mirrored | **{_fmt(counts['gitlab_repos'])}** |",
        f"<!-- FSA-COUNTS-END -->",
    ]
    new_block = "\n".join(block_lines)

    # Replace existing block if present
    pattern = r"<!-- FSA-COUNTS-START[^>]*-->.*?<!-- FSA-COUNTS-END -->"
    if re.search(pattern, original, re.DOTALL):
        updated = re.sub(pattern, new_block, original, flags=re.DOTALL)
    else:
        # Block not present — nothing to update (README must be written first)
        return False

    if updated == original:
        return False

    with open(readme_path, "w") as f:
        f.write(updated)
    return True


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    repo_root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..")
    repo_root = os.path.abspath(repo_root)
    wf_dir    = os.path.join(repo_root, ".github", "workflows")
    docs_dir  = os.path.join(repo_root, "docs")
    os.makedirs(docs_dir, exist_ok=True)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Load synopses from costs config
    synopses = load_synopses(repo_root)

    # Parse all workflow files
    paths = sorted(
        glob.glob(os.path.join(wf_dir, "*.yml")) +
        glob.glob(os.path.join(wf_dir, "*.yaml"))
    )
    all_wfs = [w for w in (parse_workflow(p) for p in paths) if w]

    # Group them
    grouped: dict[str, list] = {g[0]: [] for g in GROUPS}
    for wf in all_wfs:
        group = assign_group(wf["file"])
        grouped.setdefault(group, []).append(wf)

    # Generate and write triggers doc
    md_path  = os.path.join(docs_dir, "workflow-triggers.md")
    txt_path = os.path.join(docs_dir, "workflow-triggers.txt")

    md_content  = generate_md(grouped, all_wfs, now, synopses)
    txt_content = generate_txt(grouped, all_wfs, now, synopses)

    with open(md_path, "w") as f:
        f.write(md_content)
    with open(txt_path, "w") as f:
        f.write(txt_content)

    # Inject index + glossary via generate-book-pages.py's injector, then sync to DOCS/
    # This makes docs/ the single generation source; DOCS/ is always a copy.
    try:
        import importlib.util
        book_pages_path = os.path.join(os.path.dirname(__file__), "generate-book-pages.py")
        spec = importlib.util.spec_from_file_location("generate_book_pages", book_pages_path)
        gbp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gbp)
        gbp.inject_triggers_index(md_path, now)
    except Exception as e:
        print(f"Warning: could not inject index/glossary: {e}", file=sys.stderr)

    docs_triggers = os.path.join(repo_root, "DOCS", "workflow-triggers.md")
    shutil.copy2(md_path, docs_triggers)
    print(f"Synced: {md_path} → {docs_triggers}")

    print(f"Written: {md_path}")
    print(f"Written: {txt_path}")
    print(f"Workflows processed: {len(all_wfs)}")

    # Update README.md counts block
    counts = collect_counts(repo_root, len(all_wfs))
    if update_readme_counts(repo_root, counts, now):
        print(f"Updated: {os.path.join(repo_root, 'README.md')} (FSA-COUNTS block)")

    if update_readme_groups(repo_root, all_wfs, now):
        print(f"Updated: {os.path.join(repo_root, 'README.md')} (FSA-GROUPS block)")

    # Update DOCS/cover.md workflow count badges
    cover_path = os.path.join(repo_root, "DOCS", "cover.md")
    if os.path.exists(cover_path):
        with open(cover_path) as f:
            cover = f.read()
        n = len(all_wfs)
        cover_new = re.sub(
            r'<!-- FSA-COVER-BADGE-START -->.*?<!-- FSA-COVER-BADGE-END -->',
            f'<!-- FSA-COVER-BADGE-START -->\n<a href="https://github.com/Interested-Deving-1896/fork-sync-all/actions"><img src="https://img.shields.io/badge/workflows-{n}-0033cc?style=flat-square" alt="{n} Workflows"></a>\n<!-- FSA-COVER-BADGE-END -->',
            cover, flags=re.DOTALL
        )
        cover_new = re.sub(
            r'<!-- FSA-COVER-COUNT-START -->.*?<!-- FSA-COVER-COUNT-END -->',
            f'<!-- FSA-COVER-COUNT-START -->All {n} workflows<!-- FSA-COVER-COUNT-END -->',
            cover_new, flags=re.DOTALL
        )
        if cover_new != cover:
            with open(cover_path, "w") as f:
                f.write(cover_new)
            print(f"Updated: {cover_path} (workflow count → {n})")


if __name__ == "__main__":
    main()
