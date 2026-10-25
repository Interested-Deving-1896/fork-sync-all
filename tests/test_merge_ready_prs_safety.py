"""Safety regression tests for the local merge-ready PR helper."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "merge-ready-prs.sh"


def test_merge_ready_helper_has_valid_bash_syntax() -> None:
    result = subprocess.run(
        ["bash", "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_merge_ready_helper_defaults_to_dry_run() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'DRY_RUN="${DRY_RUN:-true}"' in script
    assert 'DRY_RUN=false ./merge-ready-prs.sh' in script


def test_invalid_dry_run_value_exits_before_token_or_network_use() -> None:
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.pop("GITHUB_TOKEN", None)
    env["DRY_RUN"] = "yes"
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    assert result.returncode == 2
    assert "DRY_RUN must be true or false" in result.stderr
    assert "GH_TOKEN not set" not in result.stderr
