"""Tests for the provider-neutral Agent Skills registry and API adapters."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/agent-skills.py"


def write_config(workspace: Path) -> Path:
    config = {
        "schema_version": 1,
        "policy": {
            "allowed_roots": [
                ".agents/skills",
                ".claude/skills",
                ".ona/skills",
                ".custom/skills",
            ],
            "allow_symlinks": False,
            "max_files_per_skill": 10,
            "max_bytes_per_skill": 100_000,
        },
        "providers": {
            "agents": {
                "label": "Open Agent Skills",
                "format": "agent-skills",
                "discovery_paths": [".agents/skills"],
                "export_path": ".agents/skills",
            },
            "claude": {
                "label": "Claude Code",
                "format": "agent-skills",
                "discovery_paths": [".claude/skills"],
                "export_path": ".claude/skills",
            },
            "ona": {
                "label": "Ona",
                "format": "legacy-markdown",
                "discovery_paths": [".ona/skills"],
                "export_path": ".ona/skills",
            },
            "custom-ai": {
                "label": "Custom AI",
                "format": "agent-skills",
                "discovery_paths": [".custom/skills"],
                "export_path": ".custom/skills",
            },
        },
    }
    path = workspace / "agent-skills.yml"
    path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
    return path


def write_skill(workspace: Path, name: str = "example-skill") -> Path:
    directory = workspace / ".agents/skills" / name
    (directory / "references").mkdir(parents=True)
    (directory / "SKILL.md").write_text(
        "---\n"
        f"name: {name}\n"
        "description: A portable example skill used by tests.\n"
        "license: Apache-2.0\n"
        "---\n\n"
        "# Example\n\nFollow the documented procedure.\n",
        encoding="utf-8",
    )
    (directory / "references/guide.md").write_text("# Guide\n", encoding="utf-8")
    return directory


def run_skills(workspace: Path, config: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--config",
            str(config),
            "--workspace-root",
            str(workspace),
            *args,
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_discovers_and_validates_canonical_and_legacy_skills(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    write_skill(tmp_path)
    legacy = tmp_path / ".ona/skills/fork-audit.md"
    legacy.parent.mkdir(parents=True)
    legacy.write_text("# Fork audit\n\nInspect the mirror.\n", encoding="utf-8")

    result = run_skills(tmp_path, config, "list", "--provider", "all")

    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["count"] == 2
    by_name = {item["name"]: item for item in payload["items"]}
    assert by_name["example-skill"]["standard_compliant"] is True
    assert by_name["example-skill"]["files"][1]["path"] == "references/guide.md"
    assert by_name["fork-audit"]["standard_compliant"] is False


def test_provider_registry_is_configuration_driven(tmp_path: Path) -> None:
    config = write_config(tmp_path)

    result = run_skills(tmp_path, config, "providers")

    payload = json.loads(result.stdout)
    assert result.returncode == 0
    assert {item["id"] for item in payload["items"]} == {
        "agents",
        "claude",
        "custom-ai",
        "ona",
    }


def test_rejects_invalid_frontmatter_and_paths_outside_roots(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    skill = write_skill(tmp_path, "Invalid_Name")

    invalid = run_skills(tmp_path, config, "validate", str(skill.relative_to(tmp_path)))
    outside = run_skills(tmp_path, config, "validate", "secrets.txt")

    assert invalid.returncode == 1
    assert "name must be" in " ".join(json.loads(invalid.stdout)["errors"])
    assert outside.returncode == 1
    assert "outside configured skill roots" in json.loads(outside.stdout)["error"]


def test_directory_name_must_match_declared_name(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    skill = write_skill(tmp_path)
    entrypoint = skill / "SKILL.md"
    entrypoint.write_text(
        entrypoint.read_text(encoding="utf-8").replace(
            "name: example-skill", "name: different-name"
        ),
        encoding="utf-8",
    )

    result = run_skills(tmp_path, config, "validate", str(skill.relative_to(tmp_path)))

    assert result.returncode == 1
    assert "differs from declared name" in " ".join(json.loads(result.stdout)["errors"])


def test_rejects_symlinks_inside_skill_package(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    skill = write_skill(tmp_path)
    target = tmp_path / "outside.txt"
    target.write_text("outside", encoding="utf-8")
    os.symlink(target, skill / "references/link.txt")

    result = run_skills(tmp_path, config, "validate", str(skill.relative_to(tmp_path)))

    assert result.returncode == 1
    assert "symbolic links are not allowed" in " ".join(json.loads(result.stdout)["errors"])


def test_rejects_configured_root_that_resolves_outside_workspace(tmp_path: Path) -> None:
    (tmp_path / ".agents").mkdir()
    os.symlink(tmp_path.parent, tmp_path / ".agents/skills")
    config = write_config(tmp_path)

    result = run_skills(tmp_path, config, "list")

    assert result.returncode == 1
    assert "must resolve inside the workspace" in json.loads(result.stdout)["error"]


def test_export_defaults_to_preview_and_materializes_on_request(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    write_skill(tmp_path)
    destination = tmp_path / ".claude/skills/example-skill"

    preview = run_skills(tmp_path, config, "export", "example-skill", "claude")
    assert preview.returncode == 0
    assert json.loads(preview.stdout)["action"] == "would-export"
    assert not destination.exists()

    applied = run_skills(
        tmp_path,
        config,
        "export",
        "example-skill",
        "claude",
        "--materialize",
    )

    assert applied.returncode == 0, applied.stdout + applied.stderr
    assert json.loads(applied.stdout)["action"] == "exported"
    assert (destination / "SKILL.md").is_file()
    assert (destination / "references/guide.md").is_file()


def test_projects_frontmatter_legacy_skill_to_custom_agent_package(tmp_path: Path) -> None:
    config = write_config(tmp_path)
    legacy = tmp_path / ".ona/skills/legacy-skill.md"
    legacy.parent.mkdir(parents=True)
    legacy.write_text(
        "---\n"
        "name: legacy-skill\n"
        "description: A legacy skill that can be projected portably.\n"
        "---\n\n"
        "# Legacy skill\n",
        encoding="utf-8",
    )

    result = run_skills(
        tmp_path,
        config,
        "export",
        "legacy-skill",
        "custom-ai",
        "--materialize",
    )

    target = tmp_path / ".custom/skills/legacy-skill/SKILL.md"
    assert result.returncode == 0, result.stdout + result.stderr
    assert target.read_text(encoding="utf-8") == legacy.read_text(encoding="utf-8")


def test_api_routes_are_toggle_gated_and_writes_require_auth() -> None:
    routes = yaml.safe_load((ROOT / "fsa-api/config/fsa-routes.yml").read_text())["routes"]
    skills = {route["path"]: route for route in routes if route["path"].startswith("/api/fsa/skills")}

    assert set(skills) == {
        "/api/fsa/skills",
        "/api/fsa/skills/providers",
        "/api/fsa/skills/validate",
        "/api/fsa/skills/export",
        "/api/fsa/skills/:name",
    }
    assert all(route["toggle"] == "skills" for route in skills.values())
    assert skills["/api/fsa/skills/validate"]["auth"] is True
    assert skills["/api/fsa/skills/export"]["auth"] is True
