import subprocess
from pathlib import Path


def test_git_platform_sync_tag_safety_regression_script():
    """Run the shell-level tag-safety checks in the standard pytest CI job."""
    repo_root = Path(__file__).resolve().parents[1]
    script = repo_root / "scripts" / "tests" / "test-git-platform-sync-tags.sh"

    result = subprocess.run(
        ["bash", str(script)],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, (
        f"Tag-safety regression script failed (exit {result.returncode}).\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "PASS: git-platform-sync tag safety regression checks" in result.stdout
