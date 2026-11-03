#!/usr/bin/env python3
"""
Detect new or materially changed managed consumers and newly registered imports.

Consumer changes to profile, tier, disabled, or skip_osp_setup are onboarding
events. Protected and delegated mirror destinations are inventory-only and
must never be onboarded as canonical source repositories.
"""
import json
import subprocess
import sys

import yaml


def _git_show(ref):
    result = subprocess.run(["git", "show", ref], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def detect(old_imports_text, new_imports_text, old_consumers_text, new_consumers_text):
    results = []
    seen = set()

    def add(name, profile="", upstream_url=""):
        if not name:
            return
        # Managed consumer entries may be qualified as owner/repo in the
        # registry; onboard-repo.yml expects the repository name only.
        if name.startswith("Interested-Deving-1896/"):
            name = name.split("/", 1)[1]
        if name not in seen:
            seen.add(name)
            results.append({"name": name, "profile": profile, "upstream_url": upstream_url})

    try:
        old = json.loads(old_imports_text) if old_imports_text is not None else []
        new = json.loads(new_imports_text) if new_imports_text is not None else []
        old_names = {entry["target_name"] for entry in old}
        for entry in new:
            if entry["target_name"] not in old_names:
                add(entry["target_name"], upstream_url=entry.get("source_url", ""))
    except Exception as ex:
        print(f"imports diff error: {ex}", file=sys.stderr)

    try:
        old_data = yaml.safe_load(old_consumers_text or "") or {}
        new_data = yaml.safe_load(new_consumers_text or "") or {}
        old_by_name = {
            entry["name"]: entry
            for entry in old_data.get("consumers", []) or []
            if isinstance(entry, dict) and entry.get("name")
        }
        for entry in new_data.get("consumers", []) or []:
            if not isinstance(entry, dict) or not entry.get("name"):
                continue
            # Mirror destinations and delegated publishers are inventory only.
            if entry.get("tier", "managed") != "managed" or entry.get("disabled", False):
                continue
            previous = old_by_name.get(entry["name"])
            relevant_fields = ("profile", "tier", "disabled", "skip_osp_setup")
            if previous is None or any(
                previous.get(field, False if field in ("disabled", "skip_osp_setup") else None)
                != entry.get(field, False if field in ("disabled", "skip_osp_setup") else None)
                for field in relevant_fields
            ):
                add(entry["name"], profile=entry.get("profile", ""))
    except Exception as ex:
        print(f"consumers diff error: {ex}", file=sys.stderr)

    return results


def main():
    results = detect(
        _git_show("HEAD~1:registered-imports.json"),
        _git_show("HEAD:registered-imports.json"),
        _git_show("HEAD~1:config/template-consumers.yml"),
        _git_show("HEAD:config/template-consumers.yml"),
    )
    print(json.dumps(results))


if __name__ == "__main__":
    main()
