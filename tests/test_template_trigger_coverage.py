"""Verify template profiles and automatic propagation triggers stay aligned.

The push workflow intentionally auto-propagates the README profile and
scaffold templates. Other profile-only template changes require a reviewed
workflow_dispatch with mode=propagate.
"""

from __future__ import annotations

import fnmatch
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "config" / "template-manifest.yml"
WORKFLOW = ROOT / ".github" / "workflows" / "sync-template.yml"


def _workflow_triggers(data: dict) -> list[str]:
    # PyYAML's YAML 1.1 resolver may interpret the unquoted key "on" as True.
    event_config = data.get("on", data.get(True, {}))
    return event_config.get("push", {}).get("paths", [])


def _source_path(entry: str) -> str:
    # Manifest remaps use source:destination; only source changes trigger sync.
    return entry.split(":", 1)[0]


def _matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def test_readme_profile_sources_are_covered_by_push_triggers() -> None:
    manifest = yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    readme_entries = manifest["profiles"]["readme-profile"]["include"]
    triggers = _workflow_triggers(workflow)

    missing = [
        _source_path(entry)
        for entry in readme_entries
        if not _matches(_source_path(entry), triggers)
    ]
    assert not missing, f"README profile sources lack automatic push triggers: {missing}"


def test_non_readme_profile_changes_are_explicitly_manual_only() -> None:
    manifest = yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))
    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    workflow = yaml.safe_load(workflow_text)
    triggers = _workflow_triggers(workflow)

    assert "manual-only" in workflow_text, (
        "The workflow must document that non-README profile changes require "
        "reviewed workflow_dispatch mode=propagate."
    )

    # These remapped scaffold sources are the only non-README profile inputs
    # intentionally covered by the broad devcontainer/ona push patterns.
    scaffold_sources = {
        ".devcontainer/devcontainer.template.json",
        ".devcontainer/automations.template.yaml",
    }
    unexpectedly_automatic: list[str] = []
    for profile_name, profile in manifest["profiles"].items():
        if profile_name == "readme-profile":
            continue
        for entry in profile.get("include", []) or []:
            source = _source_path(entry)
            if _matches(source, triggers) and source not in scaffold_sources:
                unexpectedly_automatic.append(f"{profile_name}: {source}")

    assert not unexpectedly_automatic, (
        "Non-README profile paths are unexpectedly covered by push triggers; "
        "review the automatic/manual-only contract: "
        f"{sorted(set(unexpectedly_automatic))}"
    )
