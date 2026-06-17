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
    ("Mirror Chain", [
        "mirror-to-osp", "mirror-osp-to-ooc", "mirror-osp-to-gitlab",
        "mirror-orgs", "mirror-releases", "mirror-artifacts",
        "mirror-orgs-watchdog",
    ]),
    ("OSP-Bound Repo Management", [
        "add-mirror-repo", "check-osp-ci", "setup-osp-mirrors",
    ]),
    ("Fork & Import Sync", [
        "sync-forks", "sync-pieroproietti", "sync-registered-imports",
        "import-repo", "sync-upstream-sources", "sync-btrfs",
        "sync-registry-sources", "sync-from-gitlab", "upstream-prs",
        "upstream-commits",
    ]),
    ("GitLab Sync", [
        "sync-to-gitlab",
    ]),
    ("README Management", [
        "update-readmes", "create-readmes", "translate-readmes",
        "lts-readmes", "validate-readme-render", "readme-wizard",
        "inject-badges", "patch-origins",
    ]),
    ("CI & Failure Resolution", [
        "resolve-failures", "notify-poller", "rate-limit-rerun",
        "rebase-lts", "pr-automation", "rate-limit-status",
        "check-gitlab-sync",
    ]),
    ("Maintenance & Housekeeping", [
        "reconcile-org-refs", "cleanup-branches", "cleanup-pollution",
        "sync-template", "update-infra-deps", "upstream-workflow-proposal",
        "generate-dep-graph", "token-health", "rotate-token",
        "validate-config", "cancel-post-rotation",
    ]),
    ("Full Pipeline", [
        "pre-flush-prep",
        "full-chain-flush",
        "post-flush-prep",
        "critical-deploy",
    ]),
    ("Quota & Queue Management", [
        "quota-reserve", "queue-manager", "quota-monitor",
        "update-quota-costs",
    ]),
    ("OTA System", [
        "ota-release", "ota-reconcile", "ota-self-update",
        "ota-discover", "ota-opt-in",
    ]),
    ("Documentation & Publishing", [
        "deploy-book", "generate-book-pages", "update-book-index",
        "book-export", "gitbook-oss", "translate-docs",
        "generate-notebooklm", "refresh-notebooklm",
        "update-workflow-triggers-doc",
    ]),
    ("AI & Cost Tracking", [
        "track-agent-costs", "sync-agent-prices",
    ]),
    ("Utility / On-Demand", [
        "cancel-stale-runs", "clone-org",
        "fork-neon-repos", "merge-to-monorepo", "repo-manifest",
        "sync-eggs-docs", "shallow-reclone", "gl-storage-scan",
        "list-chromium", "setup-gitlab-schedules", "trigger-artifact",
        "ci",
    ]),
    # Note: critical-deploy, pre-flush-prep, full-chain-flush → "Full Pipeline"
]

# ── Explicit sort order for groups where alphabetical is wrong ────────────────
# Maps group name → list of filename substrings in the desired display order.
# Workflows not listed here sort alphabetically after the pinned ones.
# Add a new entry here whenever a group has a natural execution/dependency order
# that differs from alphabetical — no changes to the rendering logic needed.
GROUP_SORT_KEYS: dict[str, list[str]] = {
    # Outward mirror chain: source → OSP → OOC → GitLab, then support workflows
    "Mirror Chain": [
        "mirror-to-osp",
        "mirror-osp-to-ooc",
        "mirror-osp-to-gitlab",
        "mirror-orgs",
        "mirror-releases",
        "mirror-artifacts",
        "mirror-orgs-watchdog",
    ],
    # README lifecycle: create → update → badges → translate → validate → wizard → LTS → patch
    "README Management": [
        "create-readmes",
        "update-readmes",
        "inject-badges",
        "translate-readmes",
        "validate-readme-render",
        "readme-wizard",
        "lts-readmes",
        "patch-origins",
    ],
    # CI flow: detection → rerun → resolution → status checks
    "CI & Failure Resolution": [
        "rate-limit-rerun",
        "notify-poller",
        "resolve-failures",
        "rebase-lts",
        "pr-automation",
        "rate-limit-status",
        "check-gitlab-sync",
    ],
    # Maintenance: validate first, then reconcile, cleanup, sync, generate/update
    "Maintenance & Housekeeping": [
        "validate-config",
        "reconcile-org-refs",
        "cleanup-branches",
        "cleanup-pollution",
        "sync-template",
        "update-infra-deps",
        "generate-dep-graph",
        "token-health",
        "rotate-token",
        "cancel-post-rotation",
        "upstream-workflow-proposal",
    ],
    # Full pipeline: prep → flush → verify → emergency fast-lane
    "Full Pipeline": [
        "pre-flush-prep",
        "full-chain-flush",
        "post-flush-prep",
        "critical-deploy",
    ],
    # Quota: reserve (enforcement) → queue (dedup) → monitor (health) → costs (observability)
    "Quota & Queue Management": [
        "quota-reserve",
        "queue-manager",
        "quota-monitor",
        "update-quota-costs",
    ],
    # OTA: release (push delivery) → reconcile (fallback) → self-update (pull) → discover → opt-in
    "OTA System": [
        "ota-release",
        "ota-reconcile",
        "ota-self-update",
        "ota-discover",
        "ota-opt-in",
    ],
    # Docs: build → generate → index → export → gitbook → translate → notebooklm → triggers
    "Documentation & Publishing": [
        "deploy-book",
        "generate-book-pages",
        "update-book-index",
        "book-export",
        "gitbook-oss",
        "translate-docs",
        "generate-notebooklm",
        "refresh-notebooklm",
        "update-workflow-triggers-doc",
    ],
}

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

    # Glossary
    lines.append("---")
    lines.append("")
    lines.append("<!-- FSA-GLOSSARY-START -->")
    lines.append("## Glossary")
    lines.append("")
    lines.append("> Key terms used in this document. Full glossary: [DOCS/generated/glossary.md](generated/glossary.md)")
    lines.append("")
    glossary_terms = [
        ("dispatch",         "Manual `workflow_dispatch` trigger — run from the Actions UI or via `gh workflow run`."),
        ("workflow_run",     "Trigger that fires when another named workflow completes. Used to chain workflows."),
        ("quota pre-flight", "Step that checks remaining REST quota before doing API work. Sets `skip=true` when below `MIN_QUOTA`."),
        ("MIN_QUOTA",        "Minimum remaining REST quota required before a workflow proceeds. Per-workflow value from `workflow-quota-costs.yml`."),
        ("OSP",              "OpenOS-Project-OSP — second org in the mirror chain (GitHub)."),
        ("OOC",              "OpenOS-Project-Ecosystem-OOC — third org in the mirror chain (GitHub)."),
        ("mirror chain",     "Three-org pipeline: Interested-Deving-1896 → OSP → GitLab."),
        ("DRY_RUN",          "When `true`, scripts print what they would do without making changes."),
        ("SYNC_TOKEN",       "Cross-org GitHub token. Shares the 5000 req/hr bucket with `GH_TOKEN`."),
        ("OTA",              "Over-the-air update system delivering workflow/config updates to consumer repos."),
        ("pre-flush-prep",   "Pre-flight workflow run before full-chain-flush."),
        ("full-chain-flush", "End-to-end pipeline: pre-flush-prep → mirror chain → post-flush-prep."),
        ("priority tiers",   "Tier 1 CRITICAL → Tier 4 LOW. Controls queue-manager and quota-reserve cancellation order."),
        ("consumer repo",    "Repo receiving template files from fork-sync-all via sync-template.sh."),
        ("OSP-bound repo",   "Repo mirrored into OSP and managed by fork-sync-all."),
    ]
    for term, defn in glossary_terms:
        lines.append(f"**{term}**")
        lines.append(f": {defn}")
        lines.append("")
    lines.append("<!-- FSA-GLOSSARY-END -->")
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

    print(f"Written: {md_path}")
    print(f"Written: {txt_path}")
    print(f"Workflows processed: {len(all_wfs)}")

    # Update README.md counts block
    counts = collect_counts(repo_root, len(all_wfs))
    if update_readme_counts(repo_root, counts, now):
        print(f"Updated: {os.path.join(repo_root, 'README.md')} (FSA-COUNTS block)")


if __name__ == "__main__":
    main()
