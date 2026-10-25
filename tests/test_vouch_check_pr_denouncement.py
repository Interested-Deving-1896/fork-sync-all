"""Regression tests for denouncement precedence in the PR trust gate."""

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vouch-check-pr.sh"


def test_denouncement_precedes_tier_one_registry_bypass(tmp_path: Path) -> None:
    vouched = tmp_path / "VOUCHED.td"
    vouched.write_text(
        "# Trusted handles\n"
        "github:ordinary-maintainer\n"
        "-github:blocked-maintainer [confirmed abuse]\n",
        encoding="utf-8",
    )
    registry = tmp_path / "vouch-registry.yml"
    registry.write_text(
        """entries:
  - handle: blocked-maintainer
    tier: 1
    type: individual
    active: true
    platforms:
      github: blocked-maintainer
""",
        encoding="utf-8",
    )
    output = tmp_path / "github-output.txt"
    env = {
        **os.environ,
        "GH_TOKEN": "test-token",
        "PR_NUMBER": "123",
        "PR_AUTHOR": "blocked-maintainer",
        "REPO": "example/fork-sync-all",
        "VOUCHED_FILE": str(vouched),
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "true",
        "GITHUB_OUTPUT": str(output),
    }

    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "Author is DENOUNCED — closing PR" in result.stderr
    assert "Tier 1 in registry — full pass" not in result.stderr
    assert "status=denounced" in output.read_text(encoding="utf-8")
    assert "[dry] PATCH https://api.github.com/repos/example/fork-sync-all/pulls/123" in result.stderr

def test_denouncement_wins_when_positive_entry_comes_first(tmp_path: Path) -> None:
    vouched = tmp_path / "VOUCHED.td"
    vouched.write_text(
        "github:blocked-maintainer\n"
        "-github:blocked-maintainer [confirmed abuse]\n",
        encoding="utf-8",
    )
    registry = tmp_path / "vouch-registry.yml"
    registry.write_text(
        """entries:
  - handle: blocked-maintainer
    tier: 1
    type: individual
    active: true
    platforms:
      github: blocked-maintainer
""",
        encoding="utf-8",
    )
    output = tmp_path / "github-output.txt"
    env = {
        **os.environ,
        "GH_TOKEN": "test-token",
        "PR_NUMBER": "123",
        "PR_AUTHOR": "blocked-maintainer",
        "REPO": "example/fork-sync-all",
        "VOUCHED_FILE": str(vouched),
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "true",
        "GITHUB_OUTPUT": str(output),
    }

    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "Author is DENOUNCED — closing PR" in result.stderr
    assert "Tier 1 in registry — full pass" not in result.stderr
    assert "status=denounced" in output.read_text(encoding="utf-8")
