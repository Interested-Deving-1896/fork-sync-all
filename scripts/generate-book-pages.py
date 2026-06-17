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
        "`Interested-Deving-1896` by `sync-registered-imports.yml` daily at 04:55 UTC."
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
    triggers_path = os.path.join(repo_root, "docs", "workflow-triggers.md")
    brand_path    = os.path.join(repo_root, "config", "brand.yml")

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
        (
            "source-tree.md",
            [],  # no required files — always generate
            lambda: generate_source_tree(repo_root, now),
        ),
        (
            "glossary.md",
            [],
            lambda: generate_glossary(repo_root, now),
        ),
    ]

    # Also inject index + glossary into workflow-triggers.md (both copies)
    if os.path.exists(triggers_path):
        inject_triggers_index(triggers_path, now)
        # Keep DOCS/ copy in sync
        docs_triggers = os.path.join(repo_root, "DOCS", "workflow-triggers.md")
        import shutil
        shutil.copy2(triggers_path, docs_triggers)
        print(f"Updated: {docs_triggers}")

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


# ── Source tree generator ─────────────────────────────────────────────────────

def generate_source_tree(repo_root: str, now: str) -> str:
    """Generate a full directory/file index of the repo source hierarchy."""
    SKIP_DIRS = {".git", "__pycache__", "node_modules", ".mypy_cache",
                 ".pytest_cache", "book", ".venv", "venv"}
    SKIP_EXTS = {".pyc", ".pyo", ".class", ".o", ".so", ".dylib"}

    # Descriptions for well-known directories
    DIR_DESC = {
        ".devcontainer":    "Dev container configuration (devcontainer.json, features)",
        ".github":          "GitHub Actions workflows, issue templates, dependabot config",
        ".github/workflows":"All 112 CI/CD workflow YAML files",
        ".ona":             "Ona automation config (automations.yaml)",
        "assets":           "Static assets: brand logos, docs scaffolds, OTA stubs",
        "assets/brand":     "Logo variants from discussion #125 (7 PNG options)",
        "assets/docs-scaffold": "Markdown scaffold files propagated to consumer repos",
        "config":           "Single source of truth config files for all automation",
        "dep-graph":        "Dependency graph outputs (origins.md, generated data)",
        "DOCS":             "mdBook source — all documentation pages",
        "DOCS/generated":   "Auto-generated pages (rebuilt by generate-book-pages.py)",
        "DOCS/fr":          "French translations (populated by translate-docs.yml)",
        "docs":             "Supplementary docs: workflow-triggers, NotebookLM outputs",
        "docs/notebooklm":  "NotebookLM export placeholders (audio, video, slides, etc.)",
        "scripts":          "All first-party automation scripts",
        "scripts/includes": "Shared shell + Python includes sourced by multiple scripts",
        "vendor":           "Third-party components hosted/deployed by fork-sync-all",
        "vendor/book-engine": "Agnostic book export backend (mdBook, MkDocs, Docusaurus, Pandoc)",
        "vendor/book-engine/adapters": "Per-engine build adapters",
        "vendor/book-engine/themes":   "Brand themes (FSA theme: CSS, JS, cover)",
        "vendor/infra-dashboard":      "Unified infrastructure platform (statuspage, dashboards)",
        "vendor/shell-tools":          "Vendored shell utility repos (22 tools)",
        "vendor/unified-agnostic-api": "Shell-based HTTP API framework with platform adapters",
    }

    FILE_DESC = {
        "book.toml":                    "mdBook configuration — theme, search, output settings",
        "AGENTS.md":                    "AI agent conventions, patterns, and known pitfalls",
        "README.md":                    "Project overview, mirror chain diagram, workflow count",
        "registered-imports.json":      "Upstream repos to keep in sync (registry)",
        "config/brand.yml":             "Brand config: logo, colors, substitution tokens",
        "config/gitlab-subgroups.yml":  "GitLab subgroup placement (single source of truth)",
        "config/workflow-priority-tiers.yml": "Workflow priority tiers (1=critical → 4=low)",
        "config/workflow-quota-costs.yml":    "Per-workflow REST call cost estimates",
        "config/workflow-sync.yml":           "Workflow sync registry (github_only vs paired)",
        "config/ona-projects.yml":            "Ona project registry for environment management",
        "config/template-manifest.yml":       "Template propagation profiles and file lists",
        "config/template-consumers.yml":      "Per-consumer template overrides",
        "scripts/includes/time_format.py":    "Dual-format world-timezone display (484 IANA zones)",
        "scripts/includes/gh-api.sh":         "GitHub API helpers: gh_get, gh_api, merge_upstream",
        "scripts/includes/budget.sh":         "Quota budget helpers: budget_init, budget_check",
        "scripts/includes/fsa-mode.sh":       "Managed/autonomous mode detection (3-tier check)",
        "scripts/includes/fsa-node-identity.sh": "Chain position layer: source/mirror/downstream-fork",
        "scripts/generate-book-pages.py":     "Generates DOCS/generated/ pages from config sources",
        "scripts/ona-mcp-server.py":          "FSA MCP server: 5 tools, SSE on port 8788",
        "scripts/ona-projects.sh":            "Ona project operator: sync, list, get-env",
        "scripts/sync-template.sh":           "Template propagation: CREATE/INJECT/PROPAGATE modes",
        "scripts/validate-workflow-guards.py":"Validates all 112 workflow files (5 checks)",
    }

    lines = [
        "# Source Tree",
        "",
        f"> Auto-generated {now} by `scripts/generate-book-pages.py`",
        "",
        "Complete directory and file index of the fork-sync-all source hierarchy.",
        "Click any path to view it on GitHub.",
        "",
        "---",
        "",
    ]

    BASE_URL = "https://github.com/Interested-Deving-1896/fork-sync-all/blob/main"
    TREE_URL = "https://github.com/Interested-Deving-1896/fork-sync-all/tree/main"

    def rel(path):
        return os.path.relpath(path, repo_root).replace("\\", "/")

    # Walk tree
    for dirpath, dirnames, filenames in os.walk(repo_root):
        # Prune skip dirs in-place
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        filenames = sorted(filenames)

        rel_dir = rel(dirpath)
        if rel_dir == ".":
            rel_dir = ""

        depth = rel_dir.count("/") if rel_dir else 0
        indent = "  " * depth
        dir_name = os.path.basename(dirpath) if rel_dir else "/ (root)"
        dir_link = f"{TREE_URL}/{rel_dir}" if rel_dir else TREE_URL
        dir_desc = DIR_DESC.get(rel_dir, "")

        heading = "#" * min(depth + 2, 5)
        anchor = rel_dir.replace("/", "-").replace(".", "").lower() or "root"
        lines.append(f"{heading} [{dir_name}/]({dir_link}) {{#{anchor}}}")
        if dir_desc:
            lines.append(f"*{dir_desc}*")
        lines.append("")

        if filenames:
            lines.append("| File | Description |")
            lines.append("|---|---|")
            for fname in filenames:
                ext = os.path.splitext(fname)[1]
                if ext in SKIP_EXTS:
                    continue
                rel_file = f"{rel_dir}/{fname}" if rel_dir else fname
                file_url = f"{BASE_URL}/{rel_file}"
                desc = FILE_DESC.get(rel_file, FILE_DESC.get(fname, ""))
                lines.append(f"| [`{fname}`]({file_url}) | {desc} |")
            lines.append("")

    return "\n".join(lines) + "\n"


# ── Glossary generator ────────────────────────────────────────────────────────

GLOSSARY_TERMS = [
    ("ACTOR_TZ", "IANA timezone of the person who triggered a workflow. Set via `ACTOR_TZ`, `TRIGGERER_TZ`, or `GITHUB_ACTOR_TZ` env vars. Highlighted in world_table() output."),
    ("AGENTS.md", "Convention file for AI agents working in this repo. Defines logging rules, YAML-safe shell patterns, quota management, workflow patterns, and known pitfalls."),
    ("autonomous mode", "Operating mode when fork-sync-all is not present alongside a consumer repo. Bundled workflows activate and self-manage, scoped to the repo's own owner."),
    ("book-engine", "Agnostic documentation export backend in `vendor/book-engine/`. Supports mdBook, MkDocs, Docusaurus, GitBook CLI, and Pandoc from a single Markdown source."),
    ("brand.yml", "Single source of truth for fork-sync-all branding: logo URL, color palette, substitution tokens (`{{FSA_NAME}}` etc.), and book theme settings."),
    ("budget.sh", "Shared include providing `budget_init`, `budget_check`, `budget_report`, `osp_priority_repos`, and `workflow_min_quota`. Reads per-workflow `min_quota` from `workflow-quota-costs.yml`."),
    ("chain position", "Where a fork-sync-all instance sits in the mirror chain: `source` (Interested-Deving-1896), `mirror` (OSP/OOC), or `downstream-fork` (independent fork)."),
    ("consumer repo", "Any repo that receives template files from fork-sync-all via `sync-template.sh`. Defined in `config/template-consumers.yml`."),
    ("critical-deploy", "Fast-lane workflow for emergency deployments: commit + push → aggressive queue clear → priority dispatch. Manual trigger only."),
    ("DRY_RUN", "Environment variable flag. When `true`, scripts print what they would do without making any changes. Supported by all major scripts."),
    ("Etc/GMT+N", "IANA timezone notation where the sign is inverted from UTC offset convention. `Etc/GMT+5` = UTC-5 (EST). All 484 IANA zones are included in `time_format.py`."),
    ("FSA API", "The `ona-mcp-server.py` MCP server exposing 5 tools: `list_projects`, `get_project`, `create_environment`, `sync_projects`, `get_config_summary`. Runs on port 8788."),
    ("fsa-mode.sh", "Three-tier managed/autonomous detection: (B) `FSA_MANAGED` repo variable → (A) GET `/repos/{owner}/fork-sync-all` → (C) token owner's fork-sync-all existence."),
    ("fsa-node-identity.sh", "Extends fsa-mode.sh with chain position detection. Exports `FSA_NODE_POSITION`, `FSA_NODE_OWNER`, `FSA_UPSTREAM_OWNER`, `FSA_CHAIN_DEPTH`."),
    ("full-chain-flush", "End-to-end pipeline: pre-flush-prep → mirror chain → post-flush-prep. Triggered manually or by critical-deploy."),
    ("generate-book-pages.py", "Script that generates `DOCS/generated/` pages from live config sources. Also injects index + glossary into workflow-triggers.md."),
    ("gh-api.sh", "Shared include providing `gh_api`, `gh_get`, `gh_api_graphql`, `merge_upstream`, `get_default_sha`. All status messages use `>&2`."),
    ("GitLab subgroup", "Organizational unit in the `openos-project` GitLab group. Defined in `config/gitlab-subgroups.yml`. 14 subgroups covering ~225 repos."),
    ("GraphQL", "Preferred over paginated REST for any loop fetching the same data for multiple repos. Counts as 1 REST call regardless of how many repos are queried."),
    ("GROUP_SORT_KEYS", "Dict in `generate-workflow-triggers-doc.py` mapping group names to filename-substring lists for non-alphabetical display ordering."),
    ("IANA timezone", "Standard timezone identifier from the IANA Time Zone Database (e.g. `America/Toronto`, `Europe/Paris`). `time_format.py` covers all 484 zones."),
    ("infra-core profile", "Template profile providing CI hygiene + autonomous-fallback workflows. Includes PR automation, token rotation, branch cleanup, mdBook workflows, OTA, accessibility."),
    ("managed mode", "Default operating mode when fork-sync-all is present. Bundled autonomous-fallback workflows detect this and skip themselves."),
    ("MCP server", "Model Context Protocol server. `ona-mcp-server.py` exposes FSA operations as MCP tools consumable by any MCP-compatible AI agent."),
    ("mdBook", "Rust-based static site generator used as the primary book engine. Source in `DOCS/`, config in `book.toml`, deployed to GitHub Pages by `deploy-book.yml`."),
    ("MIN_QUOTA", "Minimum remaining REST quota required before a workflow proceeds. Set per-workflow in `config/workflow-quota-costs.yml`. Typically 500–1500."),
    ("mirror chain", "Three-org pipeline: Interested-Deving-1896 → OpenOS-Project-OSP (GitHub) → openos-project (GitLab). Managed by mirror-to-osp.yml, mirror-osp-to-gitlab.yml."),
    ("node identity", "The position of a fork-sync-all instance in the mirror chain. See `fsa-node-identity.sh`. Determines which operations the instance runs."),
    ("OOC", "OpenOS-Project-Ecosystem-OOC — the third org in the mirror chain (GitHub). Receives mirrors from OSP."),
    ("OSP", "OpenOS-Project-OSP — the second org in the mirror chain (GitHub). Receives mirrors from Interested-Deving-1896."),
    ("OSP-bound repo", "A repo in Interested-Deving-1896 that is mirrored into OSP and managed by fork-sync-all (README updates, badge injection, CI checks, etc.)."),
    ("OTA", "Over-the-air update system. Delivers workflow and config updates from fork-sync-all to consumer repos without requiring manual PRs."),
    ("platform-adapter.sh", "Uniform interface for GitHub, GitLab, Gitea, Forgejo, and Codeberg. Abstracts API differences behind a common shell interface."),
    ("pre-flush-prep", "Pre-flight workflow run before full-chain-flush. Checks quota, validates configs, merges pending PRs, cleans stale branches."),
    ("priority tiers", "Four-tier workflow priority system: Tier 1 CRITICAL (never cancelled), Tier 2 HIGH (mirror/sync), Tier 3 MEDIUM (READMEs/CI), Tier 4 LOW (translation/maintenance)."),
    ("queue-manager", "Workflow that deduplicates queued runs (keeps newest per workflow) and evicts runs queued > 25 min. Runs every 30 min."),
    ("quota-reserve", "Workflow that cancels low-priority queued runs when quota drops below 1000. Uses per-workflow `min_quota` for cost-aware cancellation."),
    ("quota-snapshot.sh", "Shared include that captures a REST quota snapshot and writes it to a GitHub Actions variable. Must run after `actions/checkout`."),
    ("registered-imports.json", "Registry of upstream repos to keep in sync. Read by `sync-registered-imports.sh` and `sync-registry-sources.yml`."),
    ("SUMMARY.md", "mdBook navigation file. Defines the book's table of contents. All book-engine adapters translate this into their native nav format."),
    ("SYNC_TOKEN", "GitHub token used for cross-org operations. Shares the same 5000 req/hr REST bucket as `GH_TOKEN` (same user ID 202036334)."),
    ("template-manifest.yml", "Defines 6 named propagation profiles (full, mirror, infra-core, upstream-sync, standalone, shell-tools) and their file inclusion lists."),
    ("time_format.py", "Shared Python module providing dual 12h/24h format across all 484 IANA timezones. Includes actor/runner timezone detection and `--test` self-test."),
    ("vendor/", "Third-party components hosted/deployed by fork-sync-all. Not first-party scripts. Contains infra-dashboard, shell-tools, unified-agnostic-api, book-engine."),
    ("workflow-quota-costs.yml", "Per-workflow REST call cost registry. Drives quota-reserve.sh cancellation, budget.sh pre-flight, and DOCS/quota-costs.md documentation."),
    ("WORLD_ZONES", "Dynamic list of all 484 IANA timezone zones in `time_format.py`. Built at import time from `zoneinfo.available_timezones()`, sorted west→east."),
]


def generate_glossary(repo_root: str, now: str) -> str:
    lines = [
        "# Glossary",
        "",
        f"> Auto-generated {now} by `scripts/generate-book-pages.py`",
        "",
        "Definitions for every term, acronym, and concept used across fork-sync-all.",
        "",
        "---",
        "",
        "## Index",
        "",
    ]

    # Alphabetical index with anchor links
    letters = {}
    for term, _ in sorted(GLOSSARY_TERMS, key=lambda x: x[0].lower()):
        letter = term[0].upper()
        if letter not in letters:
            letters[letter] = []
        anchor = term.lower().replace(" ", "-").replace("/", "").replace(".", "").replace("(", "").replace(")", "")
        letters[letter].append(f"[{term}](#{anchor})")

    for letter in sorted(letters):
        lines.append(f"**{letter}:** " + " · ".join(letters[letter]) + "  ")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("<dl class=\"fsa-glossary\">")
    lines.append("")

    for term, definition in sorted(GLOSSARY_TERMS, key=lambda x: x[0].lower()):
        anchor = term.lower().replace(" ", "-").replace("/", "").replace(".", "").replace("(", "").replace(")", "")
        lines.append(f"<dt id=\"{anchor}\">{term}</dt>")
        lines.append(f"<dd>{definition}</dd>")
        lines.append("")

    lines.append("</dl>")
    lines.append("")
    return "\n".join(lines)


# ── workflow-triggers.md index + glossary injector ────────────────────────────

def inject_triggers_index(triggers_path: str, now: str) -> None:
    """Inject/replace the index block at the top of workflow-triggers.md."""
    with open(triggers_path) as f:
        content = f.read()

    # Extract all section headings and build anchor map
    sections = re.findall(r'^## (.+)$', content, re.MULTILINE)

    # Build anchor from heading text (GitHub Markdown rules)
    def anchor(text):
        return text.lower().replace(" ", "-").replace("&", "").replace("/", "").replace("(", "").replace(")", "").replace(",", "").replace(".", "").strip("-")

    # Count workflows per section
    section_counts = {}
    current = None
    for line in content.splitlines():
        m = re.match(r'^## (.+)$', line)
        if m:
            current = m.group(1)
            section_counts[current] = 0
        elif current and line.startswith("| ") and not line.startswith("| Workflow") and not line.startswith("|---"):
            section_counts[current] = section_counts.get(current, 0) + 1

    # Build the index block
    index_lines = [
        "",
        "<!-- FSA-INDEX-START -->",
        "## Index",
        "",
        "Jump to any section:",
        "",
        "| Section | Workflows |",
        "|---|---|",
    ]
    for sec in sections:
        if sec in ("Index", "Glossary", "Schedule Summary (UTC)"):
            continue
        count = section_counts.get(sec, "")
        count_str = f"{count}" if count else "—"
        index_lines.append(f"| [{sec}](#{anchor(sec)}) | {count_str} |")

    index_lines += [
        "",
        "**Quick links:** [Glossary](#glossary) · [Schedule Summary](#schedule-summary-utc) · [Source](https://github.com/Interested-Deving-1896/fork-sync-all/tree/main/.github/workflows)",
        "",
        "<!-- FSA-INDEX-END -->",
        "",
    ]

    # Build glossary block (key terms only — full glossary is in DOCS/generated/glossary.md)
    KEY_TERMS = [
        ("dispatch", "Manual `workflow_dispatch` trigger — run from the Actions UI or via `gh workflow run`."),
        ("workflow_run", "Trigger that fires when another named workflow completes. Used to chain workflows."),
        ("quota pre-flight", "Step that checks remaining REST quota before doing API work. Sets `skip=true` when below `MIN_QUOTA`."),
        ("MIN_QUOTA", "Minimum remaining REST quota required before a workflow proceeds. Per-workflow value from `workflow-quota-costs.yml`."),
        ("OSP", "OpenOS-Project-OSP — second org in the mirror chain (GitHub)."),
        ("OOC", "OpenOS-Project-Ecosystem-OOC — third org in the mirror chain (GitHub)."),
        ("mirror chain", "Three-org pipeline: Interested-Deving-1896 → OSP → GitLab."),
        ("DRY_RUN", "When `true`, scripts print what they would do without making changes."),
        ("SYNC_TOKEN", "Cross-org GitHub token. Shares the 5000 req/hr bucket with `GH_TOKEN`."),
        ("OTA", "Over-the-air update system delivering workflow/config updates to consumer repos."),
        ("pre-flush-prep", "Pre-flight workflow run before full-chain-flush."),
        ("full-chain-flush", "End-to-end pipeline: pre-flush-prep → mirror chain → post-flush-prep."),
        ("priority tiers", "Tier 1 CRITICAL → Tier 4 LOW. Controls queue-manager and quota-reserve cancellation order."),
        ("consumer repo", "Repo receiving template files from fork-sync-all via sync-template.sh."),
        ("OSP-bound repo", "Repo mirrored into OSP and managed by fork-sync-all."),
    ]

    glossary_lines = [
        "<!-- FSA-GLOSSARY-START -->",
        "## Glossary",
        "",
        "> Key terms used in this document. Full glossary: [DOCS/generated/glossary.md](generated/glossary.md)",
        "",
    ]
    for term, defn in KEY_TERMS:
        glossary_lines.append(f"**{term}**")
        glossary_lines.append(f": {defn}")
        glossary_lines.append("")

    glossary_lines.append("<!-- FSA-GLOSSARY-END -->")
    glossary_lines.append("")

    # Remove existing index/glossary blocks if present
    content = re.sub(
        r'<!-- FSA-INDEX-START -->.*?<!-- FSA-INDEX-END -->\n?',
        '', content, flags=re.DOTALL
    )
    content = re.sub(
        r'<!-- FSA-GLOSSARY-START -->.*?<!-- FSA-GLOSSARY-END -->\n?',
        '', content, flags=re.DOTALL
    )

    # Insert index after the first paragraph (after the opening --- separator)
    # and glossary before the Schedule Summary section
    index_block = "\n".join(index_lines)
    glossary_block = "\n".join(glossary_lines)

    # Insert index after first "---\n"
    content = content.replace("\n---\n\n## Mirror Chain", "\n---\n" + index_block + "\n## Mirror Chain", 1)

    # Insert glossary before Schedule Summary
    content = content.replace("\n## Schedule Summary", "\n" + glossary_block + "\n## Schedule Summary", 1)

    with open(triggers_path, "w") as f:
        f.write(content)

    print(f"Injected index + glossary into {triggers_path}")


if __name__ == "__main__":
    main()
