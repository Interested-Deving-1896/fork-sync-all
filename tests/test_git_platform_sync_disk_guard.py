import subprocess
from pathlib import Path


def test_git_platform_sync_disk_guard_regression_script():
    """Run the shell-level regression checks in the standard pytest CI job."""
    repo_root = Path(__file__).resolve().parents[1]
    script = repo_root / "scripts" / "tests" / "test-git-platform-sync-disk-guard.sh"

    result = subprocess.run(
        ["bash", str(script)],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, (
        f"Disk-guard regression script failed (exit {result.returncode}).\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "PASS: git-platform-sync disk guard regression checks" in result.stdout
