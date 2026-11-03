"""Regression checks for the Penguins-Eggs GitLab mirror script."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "sync-pieroproietti-gl-forks.sh"


def test_gitlab_mirror_script_has_valid_bash_syntax():
    result = subprocess.run(
        ["bash", "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_mirror_script_checks_destination_identity_before_writes():
    source = SCRIPT.read_text(encoding="utf-8")
    assert "path_with_namespace" in source
    assert "expected_path" in source
    assert 'if [[ "$gl_project_path" != "$expected_path" ]]' in source


def test_mirror_script_has_non_mutating_dry_run_guards():
    source = SCRIPT.read_text(encoding="utf-8")
    assert 'if [[ "$DRY_RUN" == true ]]' in source
    assert '[dry-run] Would push tags' in source
    assert '[dry-run] Would update branch' in source
    assert '[dry-run] Release creation skipped' in source
