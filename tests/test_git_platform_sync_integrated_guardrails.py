import subprocess
from pathlib import Path


def test_integrated_git_platform_sync_guardrail_regression_script():
    """Run the offline static regression checks for the integrated sync guards."""
    repo_root = Path(__file__).resolve().parents[1]
    script = repo_root / "scripts" / "tests" / "test-git-platform-sync-integrated-guardrails.sh"

    result = subprocess.run(
        ["bash", str(script)],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, (
        f"Integrated guardrail regression script failed (exit {result.returncode}).\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    assert "PASS: integrated git-platform-sync tag and disk guard checks" in result.stdout
