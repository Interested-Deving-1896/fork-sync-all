#!/usr/bin/env python3
"""
List all projects under the Chromium_Browser_OS_Deving subgroup on GitLab,
sorted by repository size descending. Prints project path, ID, and size.

Environment:
  GITLAB_TOKEN  — PAT with read_api on openos-project
  GL_API        — GitLab API base URL (default: https://gitlab.com/api/v4)
"""

import os
import sys
import json
import urllib.request
import urllib.error

GL_API = os.environ.get("GL_API", "https://gitlab.com/api/v4")
TOKEN = os.environ.get("GITLAB_TOKEN", "")
GROUP = "openos-project%2Fchromium_browser-os_deving"

headers = {"PRIVATE-TOKEN": TOKEN} if TOKEN else {}


def fetch_all_projects(group: str) -> list:
    projects = []
    page = 1
    while True:
        url = (
            f"{GL_API}/groups/{group}/projects"
            f"?include_subgroups=true&per_page=100&page={page}"
            f"&statistics=true&with_statistics=true"
        )
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req) as resp:
                batch = json.load(resp)
        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code} fetching page {page}: {e.reason}", file=sys.stderr)
            break
        if not batch:
            break
        projects.extend(batch)
        page += 1
    return projects


def fmt_bytes(b: int) -> str:
    if b >= 1_073_741_824:
        return f"{b / 1_073_741_824:.1f}G"
    if b >= 1_048_576:
        return f"{b / 1_048_576:.1f}M"
    if b >= 1_024:
        return f"{b / 1_024:.1f}K"
    return f"{b}B"


def main() -> None:
    projects = fetch_all_projects(GROUP)
    if not projects:
        print("No projects found.")
        return

    projects.sort(
        key=lambda p: p.get("statistics", {}).get("repository_size", 0),
        reverse=True,
    )

    print(f"{'ID':<10} {'Repo size':>10} {'Total':>10}  Path")
    print("-" * 90)
    for p in projects:
        s = p.get("statistics", {})
        repo_size = s.get("repository_size", 0)
        total = s.get("storage_size", 0)
        path = p.get("path_with_namespace", p.get("name", "?"))
        print(f"{p['id']:<10} {fmt_bytes(repo_size):>10} {fmt_bytes(total):>10}  {path}")

    print(f"\nTotal projects: {len(projects)}")


if __name__ == "__main__":
    main()
