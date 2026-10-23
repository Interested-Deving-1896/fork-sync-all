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
        "https://github.com:invalid/owner/repo.git",
        "https://[invalid/owner/repo.git",
        "git://github.com/owner/repo.git",
        "https://github.com/owner/repo.git\\bad",
        "https://github.com/owner/repo.git\n",
        " https://github.com/owner/repo.git",
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
    subprocess.run(["git", "-C", str(tmp_path), "remote", "add", "origin", "https://user:secret@example.invalid/org/repo.git"], check=True)

    result = invoke("status", str(tmp_path))

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["dirty"] is True
    assert payload["branch"] is not None
    assert payload["origin_configured"] is True
    assert "secret" not in result.stdout
    assert "user:" not in result.stdout
    assert tracked.read_text(encoding="utf-8") == "modified\n"

def test_git_error_redaction_hides_embedded_remote_credentials() -> None:
    import importlib.util

    spec = importlib.util.spec_from_file_location("git_workspace", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    error = "fatal: unable to access 'https://alice:secret@example.invalid/org/repo.git/': failed"
    sanitized = module.URL_USERINFO.sub(r"\1[redacted]@", error)

    assert "secret" not in sanitized
    assert "alice:" not in sanitized
    assert "https://[redacted]@example.invalid" in sanitized

def test_fetch_refuses_to_guess_when_only_non_origin_remote_exists(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Offline Test"], check=True)
    (tmp_path / "tracked.txt").write_text("initial\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "initial"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "remote", "add", "upstream", "https://example.invalid/org/repo.git"], check=True)

    result = invoke("fetch", str(tmp_path))

    assert result.returncode == 2
    assert "no origin remote" in result.stderr
    assert "fetching" not in result.stderr.lower()

def test_run_git_redacts_credentials_from_reported_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    import importlib.util

    spec = importlib.util.spec_from_file_location("git_workspace", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    def failed_git(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=["git", "fetch", "origin"],
            returncode=128,
            stdout="",
            stderr="fatal: unable to access 'https://alice:secret@example.invalid/org/repo.git/': failed",
        )

    monkeypatch.setattr(module.subprocess, "run", failed_git)
    with pytest.raises(module.WorkspaceError) as exc:
        module.run_git(["fetch", "origin"])

    assert "secret" not in str(exc.value)
    assert "alice:" not in str(exc.value)
    assert "https://[redacted]@example.invalid" in str(exc.value)



def load_workspace_module():
    import importlib.util

    spec = importlib.util.spec_from_file_location("git_workspace_test_module", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_clone_refuses_nonempty_destination_before_invoking_git(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    log = tmp_path / "git-invocations"
    fake_git = fake_bin / "git"
    fake_git.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GIT_LOG"\n', encoding="utf-8")
    fake_git.chmod(0o755)
    monkeypatch.setenv("PATH", str(fake_bin))
    monkeypatch.setenv("GIT_LOG", str(log))
    destination = tmp_path / "existing"
    destination.mkdir()
    (destination / "keep.txt").write_text("keep", encoding="utf-8")

    result = invoke("clone", "--url", "https://github.com/owner/repo.git", "--destination", str(destination))

    assert result.returncode == 2
    assert "must not exist or must be an empty directory" in result.stderr
    assert not log.exists()
    assert (destination / "keep.txt").read_text(encoding="utf-8") == "keep"


def test_clone_accepts_empty_destination_with_mock_git(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    log = tmp_path / "git-invocations"
    fake_git = fake_bin / "git"
    fake_git.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >> "$GIT_LOG"\n'
        'for arg do last="$arg"; done\n'
        'mkdir -p "$last/.git"\n',
        encoding="utf-8",
    )
    fake_git.chmod(0o755)
    monkeypatch.setenv("PATH", str(fake_bin))
    monkeypatch.setenv("GIT_LOG", str(log))
    destination = tmp_path / "empty-destination"
    destination.mkdir()

    result = invoke("clone", "--url", "https://github.com/owner/repo.git", "--destination", str(destination))

    assert result.returncode == 0, result.stderr
    assert log.read_text(encoding="utf-8").strip() == f"clone -- https://github.com/owner/repo.git {destination}"
    assert (destination / ".git").is_dir()


def test_fetch_invokes_only_origin_and_preserves_all_worktree_changes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Offline Test"], check=True)
    tracked = tmp_path / "tracked.txt"
    tracked.write_text("initial\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "initial"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "remote", "add", "origin", "https://example.invalid/org/repo.git"], check=True)
    tracked.write_text("staged edit\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.txt"], check=True)
    tracked.write_text("unstaged edit\n", encoding="utf-8")
    untracked = tmp_path / "untracked.txt"
    untracked.write_text("keep me\n", encoding="utf-8")
    before = subprocess.run(
        ["git", "-C", str(tmp_path), "status", "--porcelain=v1", "--untracked-files=all"],
        text=True, capture_output=True, check=True,
    ).stdout

    module = load_workspace_module()
    original_run_git = module.run_git
    calls: list[tuple[list[str], Path | None]] = []

    def fake_run_git(args: list[str], cwd: Path | None = None) -> str:
        calls.append((args, cwd))
        if args == ["fetch", "origin"]:
            return ""
        return original_run_git(args, cwd)

    monkeypatch.setattr(module, "run_git", fake_run_git)
    assert module.main(["fetch", str(tmp_path)]) == 0
    assert [args for args, _ in calls if args == ["fetch", "origin"]] == [["fetch", "origin"]]
    assert all(args != ["fetch", "upstream"] for args, _ in calls)

    after = subprocess.run(
        ["git", "-C", str(tmp_path), "status", "--porcelain=v1", "--untracked-files=all"],
        text=True, capture_output=True, check=True,
    ).stdout
    assert after == before
    assert tracked.read_text(encoding="utf-8") == "unstaged edit\n"
    assert untracked.read_text(encoding="utf-8") == "keep me\n"
