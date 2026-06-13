#!/usr/bin/env python3
"""
Generates three dynamic mdBook pages from config sources:

  DOCS/generated/workflow-reference.md
    — Full workflow table from config/workflow-quota-costs.yml
      (name, synopsis, tier, min_quota, cost estimates, schedule)

  DOCS/generated/registered-imports.md
    — Table of all upstream repos tracked in registered-imports.json

  DOCS/generated/subgroup-map.md
    — GitLab subgroup → repo mapping from config/gitlab-subgroups.yml

Run:
  python3 scripts/generate-book-pages.py [repo_root]

Output files are committed to DOCS/generated/ and referenced from
DOCS/SUMMARY.md. The generate-book-pages.yml workflow runs this script
before deploy-book.yml so the mdBook always reflects current config.
"""

import glob
import json
import os
import re
import sys
import yaml
from datetime import datetime, timezone


# ── Helpers ───────────────────────────────────────────────────────────────────

def now_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def load_yaml(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_json(path: str) -> list:
    with open(path) as f:
        return json.load(f)


def cron_to_human(cron: str) -> str:
    """Best-effort human description of a cron expression."""
    parts = cron.strip().split()
    if len(parts) != 5:
        return cron
    minute, hour, dom, month, dow = parts
    if minute.startswith("*/") and hour == "*":
        return f"Every {minute[2:]} min"
    if hour.startswith("*/") and dom == "*":
        return f"Every {hour[2:]}h at :{minute.zfill(2)}"
    if dom == "*" and month == "*" and dow == "*":
        if hour.isdigit():
            return f"Daily {hour.zfill(2)}:{minute.zfill(2)} UTC"
    if dow.isdigit() or dow in ("0","1","2","3","4","5","6"):
        days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        try:
            return f"Weekly {days[int(dow)]} {hour.zfill(2)}:{minute.zfill(2)} UTC"
        except Exception:
            pass
    return cron


def get_workflow_schedule(wf_dir: str, wf_file: str) -> str:
    """Extract first cron schedule from a workflow file."""
    path = os.path.join(wf_dir, wf_file)
    if not os.path.exists(path):
        return ""
    content = open(path).read()
    crons = re.findall(r"cron:\s*['\"]([^'\"]+)['\"]", content)
    if crons:
        return cron_to_human(crons[0])
    if "workflow_dispatch" in content and "schedule" not in content:
        return "Manual"
    if "push" in content and "schedule" not in content:
        return "On push"
    return ""


def get_workflow_file(wf_dir: str, name: str) -> str:
    """Find the workflow file for a given workflow name."""
    for f in glob.glob(os.path.join(wf_dir, "*.yml")) + \
             glob.glob(os.path.join(wf_dir, "*.yaml")):
        content = open(f).read()
        m = re.search(r"^name:\s*(.+)", content, re.MULTILINE)
        if m and m.group(1).strip() == name:
            return os.path.basename(f)
    return ""


# ── Page 1: Workflow Reference ────────────────────────────────────────────────

TIER_LABELS = {1: "Tier 1 — Critical", 2: "Tier 2 — High",
               3: "Tier 3 — Medium",  4: "Tier 4 — Low"}

ACTIONS_URL = "https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows"
REPO_URL    = "https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/.github/workflows"


def generate_workflow_reference(costs_path: str, tiers_path: str,
                                 wf_dir: str, now: str) -> str:
    costs_data = load_yaml(costs_path)
    tiers_data = load_yaml(tiers_path)

    # Build tier map: workflow name → tier number
    tier_map = {e["name"]: e["tier"] for e in (tiers_data.get("tiers") or [])}
    default_tier = tiers_data.get("default_tier", 3)

    workflows = costs_data.get("workflows") or []

    # Group by tier
    by_tier: dict[int, list] = {1: [], 2: [], 3: [], 4: []}
    for wf in workflows:
        name = wf.get("name", "")
        tier = tier_map.get(name, default_tier)
        by_tier.setdefault(tier, []).append(wf)

    lines = []
    lines.append("# Workflow Reference")
    lines.append("")
    lines.append("All workflows in `.github/workflows/`, grouped by priority tier.")
    lines.append("For trigger details and schedules see [Workflow Triggers](workflow-triggers.md).")
    lines.append("")
    lines.append(f"> Auto-generated on {now} from `config/workflow-quota-costs.yml`")
    lines.append("> and `config/workflow-priority-tiers.yml`.")
    lines.append("")
    lines.append("**Quota cost columns:** Low = fast/cached run · Mid = typical (p50) · High = large/uncached (p95)")
    lines.append("")

    for tier_num in sorted(by_tier.keys()):
        wfs = by_tier[tier_num]
        if not wfs:
            continue
        label = TIER_LABELS.get(tier_num, f"Tier {tier_num}")
        lines.append(f"---")
        lines.append("")
        lines.append(f"## {label}")
        lines.append("")
        lines.append("| Workflow | Synopsis | Schedule | min_quota | Low | Mid | High |")
        lines.append("|---|---|---|---|---|---|---|")
        for wf in sorted(wfs, key=lambda w: w.get("name", "")):
            name      = wf.get("name", "")
            synopsis  = wf.get("synopsis", "")
            min_q     = wf.get("min_quota", "—")
            low       = wf.get("cost_low", "—")
            mid       = wf.get("cost_mid", "—")
            high      = wf.get("cost_high", "—")
            basis     = wf.get("basis", "code-audit")
            wf_file   = get_workflow_file(wf_dir, name)
            schedule  = get_workflow_schedule(wf_dir, wf_file) if wf_file else ""
            # Add observed marker if basis is observed
            mid_str   = f"{mid} ✦" if basis == "observed" else str(mid)
            if wf_file:
                name_cell = f"[{name}]({REPO_URL}/{wf_file})"
            else:
                name_cell = name
            lines.append(
                f"| {name_cell} | {synopsis} | {schedule} "
                f"| {min_q} | {low} | {mid_str} | {high} |"
            )
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("✦ Mid value is an observed p50 measurement. All other values are code-audit estimates.")
    lines.append("")
    return "\n".join(lines)


# ── Page 2: Registered Imports ────────────────────────────────────────────────

PLATFORM_ICONS = {
    "github":    "GitHub",
    "gitlab":    "GitLab",
    "bitbucket": "Bitbucket",
    "gitea":     "Gitea",
}


def generate_registered_imports(imports_path: str, now: str) -> str:
    imports = load_json(imports_path)

    # Group by platform
    by_platform: dict[str, list] = {}
    for entry in imports:
        platform = entry.get("platform", "github")
        by_platform.setdefault(platform, []).append(entry)

    lines = []
    lines.append("# Registered Imports")
    lines.append("")
    lines.append(
        f"All {len(imports)} upstream repositories tracked in "
        "`registered-imports.json`. These are synced to "
        "`Interested-Deving-1896` by `sync-registered-imports.yml` every 6 hours."
    )
    lines.append("")
    lines.append(f"> Auto-generated on {now} from `registered-imports.json`.")
    lines.append("")

    for platform in sorted(by_platform.keys()):
        entries = sorted(by_platform[platform], key=lambda e: e.get("target_name", ""))
        label = PLATFORM_ICONS.get(platform, platform.title())
        lines.append(f"## {label} ({len(entries)})")
        lines.append("")
        lines.append("| Target repo | Source URL | Added |")
        lines.append("|---|---|---|")
        for e in entries:
            target  = e.get("target_name", "")
            source  = e.get("source_url", "")
            added   = e.get("added", "")[:10]  # date only
            gh_link = f"https://github.com/Interested-Deving-1896/{target}"
            lines.append(f"| [{target}]({gh_link}) | [{source}]({source}) | {added} |")
        lines.append("")

    return "\n".join(lines)


# ── Page 3: GitLab Subgroup Map ───────────────────────────────────────────────

GITLAB_BASE = "https://gitlab.com/openos-project"
AGENTS_IDS = {
    "git-management_deving":          130516820,
    "penguins-eggs_deving":           130516402,
    "immutable-filesystem_deving":    130516465,
    "linux-kernel_filesystem_deving": 130516188,
    "incus_deving":                   130516536,
    "taubyte_deving":                 133909500,
    "neon-deving":                    130739746,
    "ops":                            130734009,
    "yaml-tooling_deving":            133909501,
    "cachyos_deving":                 133909503,
    "ai-agents_deving":               133909504,
    "rust-systems_deving":            133954601,
}


def generate_subgroup_map(subgroups_path: str, now: str) -> str:
    data = load_yaml(subgroups_path)
    subgroups = data.get("subgroups", {}) or {}

    total_repos = sum(len(sg.get("repos") or []) for sg in subgroups.values())

    lines = []
    lines.append("# GitLab Subgroup Map")
    lines.append("")
    lines.append(
        f"All {total_repos} OSP-bound repositories mapped to their GitLab subgroup "
        f"under [`openos-project`]({GITLAB_BASE}). "
        "This is the single source of truth used by `mirror-osp-to-gitlab.sh`."
    )
    lines.append("")
    lines.append(f"> Auto-generated on {now} from `config/gitlab-subgroups.yml`.")
    lines.append("")
    lines.append("| Subgroup | GitLab ID | Repos | GitLab URL |")
    lines.append("|---|---|---|---|")

    for slug, sg in subgroups.items():
        repos     = sg.get("repos") or []
        gitlab_id = AGENTS_IDS.get(slug, sg.get("gitlab_id", "—"))
        url       = f"{GITLAB_BASE}/{slug}"
        lines.append(f"| `{slug}` | {gitlab_id} | {len(repos)} | [{url}]({url}) |")

    lines.append("")
    lines.append("---")
    lines.append("")

    for slug, sg in subgroups.items():
        repos = sg.get("repos") or []
        if not repos:
            continue
        url = f"{GITLAB_BASE}/{slug}"
        lines.append(f"## [{slug}]({url})")
        lines.append("")
        lines.append("| Repo | GitHub | GitLab |")
        lines.append("|---|---|---|")
        for repo in sorted(repos):
            gh_url = f"https://github.com/OpenOS-Project-OSP/{repo}"
            gl_url = f"{GITLAB_BASE}/{slug}/{repo}"
            lines.append(f"| `{repo}` | [GitHub]({gh_url}) | [GitLab]({gl_url}) |")
        lines.append("")

    return "\n".join(lines)


# ── Page 4: OSP Dependency Graph (pass-through from dep-graph/origins.md) ────

def generate_origins_page(origins_md_path: str) -> str:
    """Pass dep-graph/origins.md through as a DOCS page with a stable heading."""
    with open(origins_md_path) as f:
        content = f.read()
    # Strip the top-level heading if present — SUMMARY.md provides the nav title
    lines = content.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    return "\n".join(lines).lstrip("\n")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    repo_root = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(__file__), "..")
    repo_root = os.path.abspath(repo_root)

    out_dir = os.path.join(repo_root, "DOCS", "generated")
    os.makedirs(out_dir, exist_ok=True)

    wf_dir        = os.path.join(repo_root, ".github", "workflows")
    costs_path    = os.path.join(repo_root, "config", "workflow-quota-costs.yml")
    tiers_path    = os.path.join(repo_root, "config", "workflow-priority-tiers.yml")
    imports_path  = os.path.join(repo_root, "registered-imports.json")
    subgroups_path = os.path.join(repo_root, "config", "gitlab-subgroups.yml")
    origins_path  = os.path.join(repo_root, "dep-graph", "origins.md")

    now = now_str()

    # Each page is only generated when its source file(s) exist.
    # This allows the same script to run on consumer repos that only have a
    # subset of the config files (e.g. no registered-imports.json or
    # gitlab-subgroups.yml).
    candidate_pages = [
        (
            "workflow-reference.md",
            [costs_path, tiers_path],
            lambda: generate_workflow_reference(costs_path, tiers_path, wf_dir, now),
        ),
        (
            "registered-imports.md",
            [imports_path],
            lambda: generate_registered_imports(imports_path, now),
        ),
        (
            "subgroup-map.md",
            [subgroups_path],
            lambda: generate_subgroup_map(subgroups_path, now),
        ),
        (
            "origins.md",
            [origins_path],
            lambda: generate_origins_page(origins_path),
        ),
    ]

    written = 0
    for filename, required_files, generator in candidate_pages:
        missing = [f for f in required_files if not os.path.exists(f)]
        if missing:
            print(f"Skipping {filename} — source file(s) not found: {', '.join(missing)}")
            continue
        path = os.path.join(out_dir, filename)
        with open(path, "w") as f:
            f.write(generator())
        print(f"Written: {path}")
        written += 1

    print(f"Generated {written} page(s) in {out_dir}")


if __name__ == "__main__":
    main()
