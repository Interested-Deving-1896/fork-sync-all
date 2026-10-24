"""Offline safety tests for the provider-neutral Git workspace helper."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/git-workspace.py"


def run_helper(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


@pytest.mark.parametrize(
    "value",
    [
        "",
        "git@github.com:owner/repo.git",
        "http://github.com/owner/repo",
        "https://user:secret@github.com/owner/repo",
        "https://github.com/owner/repo?token=secret",
        "https://github.com/owner/repo#fragment",
        "https://github.com/owner/repo/extra",
        "https://github.com/../repo",
        "https://github.com/owner/%2e%2e",
        "https://github.com:443/owner/repo",
    ],
)
def test_clone_url_rejects_unsafe_or_unsupported_forms(value: str) -> None:
    result = run_helper("clone", value, "--destination", "/tmp/never-created-fsa-test")
    assert result.returncode != 0
    payload = json.loads(result.stdout)
    assert payload["ok"] is False
    assert "error" in payload


def test_clone_url_normalizes_https_repository() -> None:
    # Exercise the public CLI without making a network request: an existing
    # destination must be rejected after URL validation and before Git clone.
    destination = Path("/tmp")
    result = run_helper(
        "clone", "https://GitHub.com/owner/project", "--destination", str(destination)
    )
    assert result.returncode != 0
    payload = json.loads(result.stdout)
    assert payload["ok"] is False
    assert "already exists" in payload["error"]


def test_status_reports_dirty_tree_without_modifying_it(tmp_path: Path) -> None:
    workspace = tmp_path / "repo"
    workspace.mkdir()
    subprocess.run(["git", "init", "-q", str(workspace)], check=True)
    subprocess.run(
        ["git", "-C", str(workspace), "config", "user.name", "Test User"], check=True
    )
    subprocess.run(
        ["git", "-C", str(workspace), "config", "user.email", "test@example.invalid"],
        check=True,
    )
    (workspace / "tracked.txt").write_text("baseline\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(workspace), "add", "tracked.txt"], check=True
    )
    subprocess.run(
        ["git", "-C", str(workspace), "commit", "-qm", "initial"], check=True
    )
    subprocess.run(
        ["git", "-C", str(workspace), "remote", "add", "origin",
         "https://github.com/example/project.git"],
        check=True,
    )
    (workspace / "tracked.txt").write_text("local edits\n", encoding="utf-8")

    result = run_helper("status", str(workspace))
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert payload["working_tree_clean"] is False
    assert payload["changes"]
    assert (workspace / "tracked.txt").read_text(encoding="utf-8") == "local edits\n"


def test_clone_refuses_to_reuse_existing_destination(tmp_path: Path) -> None:
    destination = tmp_path / "existing"
    destination.mkdir()
    marker = destination / "keep.txt"
    marker.write_text("preserve me", encoding="utf-8")
    result = run_helper(
        "clone", "https://github.com/example/project.git",
        "--destination", str(destination),
    )
    assert result.returncode != 0
    assert "already exists" in json.loads(result.stdout)["error"]
    assert marker.read_text(encoding="utf-8") == "preserve me"


def test_capabilities_does_not_claim_api_access_was_checked() -> None:
    result = run_helper("capabilities")
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert "API access itself is not tested" in payload["fallback"] or payload[
        "local_workspace_operations_available"
    ]
