#!/usr/bin/env python3
"""summary_to_nav.py — convert SUMMARY.md to engine-specific nav formats.

Outputs:
  --format mkdocs      → mkdocs.yml (stdout)
  --format docusaurus  → sidebars.js (stdout)
  --format filelist    → space-separated file list for pandoc (stdout)
"""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path


def parse_summary(summary_path: str) -> list[dict]:
    """Parse SUMMARY.md into a flat list of {title, path, level} dicts."""
    entries = []
    with open(summary_path) as f:
        for line in f:
            m = re.match(r'^(\s*)-\s+\[([^\]]+)\]\(([^)]+)\)', line)
            if m:
                indent, title, path = m.group(1), m.group(2), m.group(3)
                level = len(indent) // 2
                entries.append({"title": title, "path": path, "level": level})
    return entries


def to_mkdocs(entries: list[dict], title: str, logo: str, theme_dir: str) -> str:
    """Generate mkdocs.yml content."""
    logo_rel = logo if logo else ""
    lines = [
        f"site_name: \"{title}\"",
        f"site_description: \"Sync and mirror infrastructure for the Interested-Deving-1896 / OpenOS-Project org chain\"",
        f"site_url: \"https://interested-deving-1896.github.io/fork-sync-all/\"",
        f"repo_url: \"https://github.com/Interested-Deving-1896/fork-sync-all\"",
        f"repo_name: \"Interested-Deving-1896/fork-sync-all\"",
        f"edit_uri: \"edit/main/DOCS/\"",
        "",
        "theme:",
        "  name: material",
        "  custom_dir: vendor/book-engine/themes/fsa/mkdocs-overrides",
        f"  logo: {logo_rel}" if logo_rel else "  # logo: assets/brand/logo-option-1.png",
        "  favicon: assets/brand/favicon.png",
        "  palette:",
        "    - scheme: default",
        "      primary: custom",
        "      accent: custom",
        "      toggle:",
        "        icon: material/brightness-7",
        "        name: Switch to dark mode",
        "    - scheme: slate",
        "      primary: custom",
        "      accent: custom",
        "      toggle:",
        "        icon: material/brightness-4",
        "        name: Switch to light mode",
        "  features:",
        "    - navigation.tabs",
        "    - navigation.sections",
        "    - navigation.expand",
        "    - navigation.top",
        "    - search.highlight",
        "    - search.share",
        "    - content.code.copy",
        "    - content.action.edit",
        "",
        "extra_css:",
        "  - vendor/book-engine/themes/fsa/mkdocs-extra.css",
        "",
        "extra:",
        "  social:",
        "    - icon: fontawesome/brands/github",
        "      link: https://github.com/Interested-Deving-1896/fork-sync-all",
        "",
        "plugins:",
        "  - search",
        "  - tags",
        "",
        "markdown_extensions:",
        "  - admonition",
        "  - pymdownx.details",
        "  - pymdownx.superfences",
        "  - pymdownx.tabbed:",
        "      alternate_style: true",
        "  - pymdownx.highlight:",
        "      anchor_linenums: true",
        "  - toc:",
        "      permalink: true",
        "",
        "nav:",
    ]

    # Build nav tree
    stack: list[tuple[int, list]] = [(-1, lines)]
    for e in entries:
        indent = "  " * (e["level"] + 1)
        lines.append(f"{indent}- \"{e['title']}\": {e['path']}")

    return "\n".join(lines) + "\n"


def to_docusaurus(entries: list[dict]) -> str:
    """Generate sidebars.js content."""
    items = []
    for e in entries:
        path = e["path"].replace(".md", "").lstrip("./")
        items.append(f'  "{path}",')
    body = "\n".join(items)
    return f"""// sidebars.js — auto-generated from SUMMARY.md by summary_to_nav.py
// Do not edit manually.
/** @type {{import('@docusaurus/plugin-content-docs').SidebarsConfig}} */
const sidebars = {{
  docs: [
{body}
  ],
}};
module.exports = sidebars;
"""


def to_filelist(entries: list[dict], src_dir: str) -> str:
    """Return space-separated list of markdown files in SUMMARY order."""
    files = []
    for e in entries:
        p = Path(src_dir) / e["path"]
        if p.exists():
            files.append(str(p))
    return " ".join(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["mkdocs", "docusaurus", "filelist"], required=True)
    ap.add_argument("--summary", default="DOCS/SUMMARY.md")
    ap.add_argument("--title", default="fork-sync-all")
    ap.add_argument("--logo", default="assets/brand/logo-option-1.png")
    ap.add_argument("--theme-dir", default="vendor/book-engine/themes/fsa")
    ap.add_argument("--src-dir", default="DOCS")
    args = ap.parse_args()

    entries = parse_summary(args.summary)

    if args.format == "mkdocs":
        print(to_mkdocs(entries, args.title, args.logo, args.theme_dir))
    elif args.format == "docusaurus":
        print(to_docusaurus(entries))
    elif args.format == "filelist":
        print(to_filelist(entries, args.src_dir))


if __name__ == "__main__":
    main()
