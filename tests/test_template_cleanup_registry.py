"""Tests for registry-driven, fail-closed cleanup target selection."""
from __future__ import annotations

import pytest

from scripts.template_cleanup_registry import resolve_targets


def test_bare_names_route_only_to_documented_default_owner() -> None:
    targets, _ = resolve_targets(
        {"consumers": [{"name": "alpha"}, {"name": "beta"}]},
        "Interested-Deving-1896",
    )
    assert targets == [
        ("Interested-Deving-1896", "alpha"),
        ("Interested-Deving-1896", "beta"),
    ]


def test_qualified_managed_target_preserves_explicit_owner() -> None:
    targets, _ = resolve_targets(
        {"consumers": [{"name": "Example-Org/project", "tier": "managed"}]},
        "Interested-Deving-1896",
    )
    assert targets == [("Example-Org", "project")]


def test_protected_delegated_and_disabled_consumers_are_skipped() -> None:
    targets, skipped = resolve_targets(
        {"consumers": [
            {"name": "source", "tier": "protected"},
            {"name": "downstream", "tier": "delegated", "delegated_to": "owner/source"},
            {"name": "paused", "disabled": True},
            {"name": "active"},
        ]},
        "Interested-Deving-1896",
    )
    assert targets == [("Interested-Deving-1896", "active")]
    assert skipped == [
        "source: tier=protected",
        "downstream: tier=delegated",
        "paused: disabled",
    ]


def test_duplicate_canonical_targets_fail_closed() -> None:
    with pytest.raises(ValueError, match="duplicate canonical target"):
        resolve_targets(
            {"consumers": [
                {"name": "alpha"},
                {"name": "Interested-Deving-1896/alpha"},
            ]},
            "Interested-Deving-1896",
        )


@pytest.mark.parametrize("name", ["", "/repo", "owner/", "one/two/three", "bad name"])
def test_malformed_names_fail_closed(name: str) -> None:
    with pytest.raises(ValueError):
        resolve_targets({"consumers": [{"name": name}]}, "Interested-Deving-1896")


def test_invalid_tier_and_disabled_type_fail_closed() -> None:
    with pytest.raises(ValueError, match="invalid tier"):
        resolve_targets({"consumers": [{"name": "alpha", "tier": "unknown"}]}, "owner")
    with pytest.raises(ValueError, match="disabled must be boolean"):
        resolve_targets({"consumers": [{"name": "alpha", "disabled": "false"}]}, "owner")


def test_registry_without_consumers_fails_closed() -> None:
    with pytest.raises(ValueError, match="'consumers' must be a list"):
        resolve_targets({}, "owner")

import subprocess
from pathlib import Path


def test_cli_emits_tab_separated_targets_and_reports_skips(tmp_path: Path) -> None:
    import yaml

    registry = tmp_path / "consumers.yml"
    registry.write_text(
        yaml.safe_dump({"consumers": [
            {"name": "managed"},
            {"name": "org/qualified"},
            {"name": "protected", "tier": "protected"},
        ]}),
        encoding="utf-8",
    )
    result = subprocess.run(
        ["python3", "scripts/template_cleanup_registry.py", "--default-owner",
         "default-owner", str(registry)],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0
    assert result.stdout.splitlines() == [
        "default-owner\tmanaged",
        "org\tqualified",
    ]
    assert "SKIP protected: tier=protected" in result.stderr


def test_cleanup_script_is_report_only_and_registry_driven() -> None:
    script = Path("scripts/cleanup-pollution.sh").read_text(encoding="utf-8")
    guard = script.index('if [[ "$DRY_RUN" != "true" ]]')
    token_check = script.index(': "${SYNC_TOKEN:?SYNC_TOKEN is required}"')
    assert guard < token_check
    assert "template_cleanup_registry.py" in script
    assert "GH_CONSUMERS=(" not in script
    assert "GL_REPOS=(" not in script
    assert "gl_cleanup_repo" not in script
    assert " -X DELETE " not in script
    assert "repository/files/" not in script
    assert "audit_template_file_ownership.py" in script
    assert "--filter=blob:none --no-checkout --no-tags" in script
    assert "OWNERSHIP VERIFIED (report only" in script
    assert "UNVERIFIED" in script

    workflow = Path(".github/workflows/cleanup-pollution.yml").read_text(encoding="utf-8")
    assert "GITLAB_TOKEN" not in workflow
    assert "Report candidate paths in registered consumer repos" in workflow
    assert "report-only" in workflow


def test_repository_consumer_registry_has_unambiguous_managed_routes() -> None:
    import yaml

    data = yaml.safe_load(Path("config/template-consumers.yml").read_text(encoding="utf-8"))
    targets, skipped = resolve_targets(data, "Interested-Deving-1896")
    assert targets
    assert ("Interested-Deving-1896", "btrfs-dwarfs-framework") in targets
    assert ("OpenOS-Project-OSP", "OpenOS-Project-OSP") not in targets
    assert any("tier=protected" in reason for reason in skipped)
    assert any("tier=delegated" in reason for reason in skipped)


def test_cleanup_shell_script_parses_without_syntax_errors() -> None:
    result = subprocess.run(
        ["bash", "-n", "scripts/cleanup-pollution.sh"],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stderr
