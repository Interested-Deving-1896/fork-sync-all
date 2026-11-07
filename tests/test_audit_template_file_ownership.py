"""Tests for the fail-closed template ownership history auditor."""
from __future__ import annotations

import subprocess
from pathlib import Path

from scripts.audit_template_file_ownership import audit_path


def run(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def commit(repo: Path, message: str, path: str, content: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    run(repo, "add", path)
    run(repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", message)


def init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "consumer"
    repo.mkdir()
    run(repo, "init")
    run(repo, "config", "user.name", "Test")
    run(repo, "config", "user.email", "test@example.invalid")
    commit(repo, "consumer: initialize repository", "README.md", "baseline")
    return repo


def test_sync_created_file_with_only_sync_history_is_eligible(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    path = ".github/workflows/consumer.yml"
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "template v1")
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "template v2")
    result = audit_path(repo, path)
    assert result["eligible"] is True
    assert result["reason"] == "complete-template-only-path-history"
    assert result["evidence_commits"] == 2


def test_preexisting_file_is_not_eligible(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    path = ".github/workflows/consumer.yml"
    commit(repo, "consumer: add workflow", path, "owned by consumer")
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "overwritten")
    result = audit_path(repo, path)
    assert result["eligible"] is False
    assert result["reason"] == "consumer-or-unverified-history"


def test_consumer_modified_file_is_not_eligible_even_after_later_sync(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    path = ".github/workflows/consumer.yml"
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "template v1")
    commit(repo, "consumer: customize workflow", path, "consumer version")
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "template v2")
    result = audit_path(repo, path)
    assert result["eligible"] is False
    assert result["reason"] == "consumer-or-unverified-history"


def test_missing_path_is_not_eligible(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    commit(repo, "consumer: add readme", "README.md", "hello")
    result = audit_path(repo, "missing.txt")
    assert result["eligible"] is False
    assert result["reason"] == "not-tracked"


def test_shallow_history_fails_closed(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    path = "file.txt"
    commit(repo, f"chore: sync template file {path} [skip ci]", path, "template")
    (repo / ".git" / "shallow").write_text(run(repo, "rev-parse", "HEAD") + "\\n", encoding="utf-8")
    result = audit_path(repo, path)
    assert result["eligible"] is False
    assert result["reason"] == "shallow-history"


def test_invalid_path_fails_closed(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    result = audit_path(repo, "../outside")
    assert result["eligible"] is False
    assert result["reason"] == "invalid-relative-path"
