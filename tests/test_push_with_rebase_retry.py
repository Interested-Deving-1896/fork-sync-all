"""Regression coverage for race-safe workflow pushes."""

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/push-with-rebase-retry.sh"
WORKFLOW = ROOT / ".github/workflows/sync-uaa-vendor.yml"


def git(*args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=True
    )


def configure(repo: Path) -> None:
    git("config", "user.name", "Test Bot", cwd=repo)
    git("config", "user.email", "test@example.invalid", cwd=repo)


def seed_repositories(tmp_path: Path) -> tuple[Path, Path, Path]:
    remote = tmp_path / "remote.git"
    seed = tmp_path / "seed"
    worker = tmp_path / "worker"
    concurrent = tmp_path / "concurrent"

    git("init", "--bare", "--initial-branch=main", str(remote), cwd=tmp_path)
    git("clone", str(remote), str(seed), cwd=tmp_path)
    configure(seed)
    (seed / "base.txt").write_text("base\n")
    git("add", "base.txt", cwd=seed)
    git("commit", "-m", "base", cwd=seed)
    git("push", "origin", "main", cwd=seed)

    git("clone", str(remote), str(worker), cwd=tmp_path)
    git("clone", str(remote), str(concurrent), cwd=tmp_path)
    configure(worker)
    configure(concurrent)
    return remote, worker, concurrent


def commit_file(repo: Path, name: str, contents: str) -> None:
    (repo / name).write_text(contents)
    git("add", name, cwd=repo)
    git("commit", "-m", f"update {name}", cwd=repo)


def run_script(repo: Path, *, attempts: str = "4") -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "PUSH_REMOTE": "origin",
        "PUSH_BRANCH": "main",
        "PUSH_REBASE_ATTEMPTS": attempts,
    }
    return subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_rebases_local_commit_over_concurrent_main_update(tmp_path: Path) -> None:
    remote, worker, concurrent = seed_repositories(tmp_path)
    commit_file(worker, "vendor.txt", "vendor update\n")
    commit_file(concurrent, "control-plane.txt", "merged PR\n")
    git("push", "origin", "main", cwd=concurrent)

    result = run_script(worker)

    assert result.returncode == 0, result.stderr
    verification = git("clone", str(remote), str(tmp_path / "verify"), cwd=tmp_path)
    assert verification.returncode == 0
    assert (tmp_path / "verify" / "vendor.txt").read_text() == "vendor update\n"
    assert (tmp_path / "verify" / "control-plane.txt").read_text() == "merged PR\n"


def test_rebase_conflict_fails_without_overwriting_remote(tmp_path: Path) -> None:
    remote, worker, concurrent = seed_repositories(tmp_path)
    commit_file(worker, "base.txt", "worker change\n")
    commit_file(concurrent, "base.txt", "concurrent change\n")
    concurrent_head = git("rev-parse", "HEAD", cwd=concurrent).stdout.strip()
    git("push", "origin", "main", cwd=concurrent)

    result = run_script(worker)

    assert result.returncode != 0
    assert "conflicted; no push was attempted" in result.stderr
    remote_head = git("--git-dir", str(remote), "rev-parse", "main", cwd=tmp_path).stdout.strip()
    assert remote_head == concurrent_head


def test_invalid_retry_budget_fails_closed(tmp_path: Path) -> None:
    _, worker, _ = seed_repositories(tmp_path)
    commit_file(worker, "vendor.txt", "vendor update\n")

    result = run_script(worker, attempts="0")

    assert result.returncode != 0
    assert "must be a positive integer" in result.stderr


def test_non_concurrency_push_rejection_is_not_retried(tmp_path: Path) -> None:
    remote, worker, _ = seed_repositories(tmp_path)
    commit_file(worker, "vendor.txt", "vendor update\n")
    hook_log = tmp_path / "hook.log"
    hook = remote / "hooks/pre-receive"
    hook.write_text(
        f"#!/usr/bin/env bash\necho rejected >> {hook_log}\n"
        "echo 'policy rejected this push' >&2\nexit 1\n"
    )
    hook.chmod(0o755)

    result = run_script(worker)

    assert result.returncode != 0
    assert "not retrying a non-concurrency error" in result.stderr
    assert hook_log.read_text().splitlines() == ["rejected"]


def test_sync_uaa_workflow_uses_race_safe_push_helper() -> None:
    workflow = WORKFLOW.read_text()

    assert "bash scripts/push-with-rebase-retry.sh" in workflow
    assert "git push origin main" not in workflow
    assert "- 'scripts/push-with-rebase-retry.sh'" in workflow
    assert "github.event_name == 'push'" in workflow
    assert "sync-uaa-vendor-push" in workflow
    assert "sync-uaa-vendor-writer" in workflow
