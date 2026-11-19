import os
import subprocess


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_allowlist_validator_scans_every_workflow():
    workflows = [
        name for name in os.listdir(os.path.join(REPO_ROOT, ".github", "workflows"))
        if name.endswith((".yml", ".yaml"))
    ]
    result = subprocess.run(
        ["bash", "scripts/validate-workflows.sh"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"all {len(workflows)} workflows are on the allowlist" in result.stdout
