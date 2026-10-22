"""Offline tests for the safe local Git workspace helper."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/git-workspace.py"


def invoke(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )


@pytest.mark.parametrize("coordinates", ["owner/repo", "OpenOS-Project-OSP/fork-sync-all", "org_1/repo.name"])
def test_accepts_repository_coordinates(coordinates: str) -> None:
    result = invoke("validate", "--coordinates", coordinates)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["valid"] is True


@pytest.mark.parametrize("coordinates", ["", "owner", "owner/repo/extra", "../repo", "owner/..", "https://github.com/a/b"])
def test_rejects_invalid_repository_coordinates(coordinates: str) -> None:
    result = invoke("validate", "--coordinates", coordinates)
    assert result.returncode == 2


@pytest.mark.parametrize(
    "url",
    [
        "https://github.com/owner/repo.git",
        "ssh://git@gitlab.com/group/project.git",
    ],
)
def test_accepts_supported_remote_urls(url: str) -> None:
    result = invoke("validate", "--url", url)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    "url",
    [
        "file:///tmp/repo",
        "/tmp/repo",
        "https://user:secret@github.com/owner/repo.git",
        "https://github.com",
        "https://github.com/owner/repo?token=secret",
        "git://github.com/owner/repo.git",
    ],
)
def test_rejects_unsafe_remote_urls(url: str) -> None:
    result = invoke("validate", "--url", url)
    assert result.returncode == 2


def test_requires_exactly_one_validation_input() -> None:
    assert invoke("validate").returncode == 2
    assert invoke("validate", "--coordinates", "owner/repo", "--url", "https://github.com/a/b").returncode == 2


def test_helper_exposes_no_mutating_git_commands() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    assert '"push"' not in source
    assert '"reset"' not in source
    assert '"merge"' not in source
    assert '"checkout"' not in source


def test_status_reports_dirty_worktree_without_modifying_it(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Offline Test"], check=True)
    tracked = tmp_path / "tracked.txt"
    tracked.write_text("initial\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "initial"], check=True)
    tracked.write_text("modified\n", encoding="utf-8")

    result = invoke("status", str(tmp_path))

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["dirty"] is True
    assert payload["branch"] is not None
    assert tracked.read_text(encoding="utf-8") == "modified\n"
