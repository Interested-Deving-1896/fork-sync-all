"""Fixture-driven tests for the GitLab mirror discovery preflight.

All network and git commands are replaced with local fakes. These tests never
contact GitLab/GitHub or push to a remote repository.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "sync-upstream-mirrors.sh"


def project(index: int, *, name: str | None = None) -> dict[str, object]:
    return {
        "id": index + 1,
        "name": name or f"mirror-{index}",
        "http_url_to_repo": f"https://gitlab.com/openos-project/upstream-mirrors/mirror-{index}.git",
        "import_url": f"https://github.com/example/mirror-{index}.git",
    }


def harness(tmp_path: Path, pages: dict[int, object], **overrides: str) -> tuple[subprocess.CompletedProcess[str], str]:
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    for page_number, payload in pages.items():
        (fixtures / f"page-{page_number}.json").write_text(
            json.dumps(payload), encoding="utf-8"
        )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(
        """#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
url = args[-1]
page = int(url.split("page=")[-1].split("&")[0])
output = args[args.index("--output") + 1]
fixture = pathlib.Path(os.environ["FAKE_FIXTURES"]) / f"page-{page}.json"
pathlib.Path(output).write_text(fixture.read_text() if fixture.exists() else "[]")
if os.environ.get("FAKE_TRANSPORT_FAIL_PAGE") == str(page):
    raise SystemExit(7)
status = "500" if os.environ.get("FAKE_HTTP_ERROR_PAGE") == str(page) else "200"
sys.stdout.write(status)
""",
        encoding="utf-8",
    )
    curl.chmod(0o755)

    git = fake_bin / "git"
    git.write_text(
        """#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$FAKE_GIT_LOG"
if [[ "$1" == "clone" ]]; then
  for arg in "$@"; do target="$arg"; done
  mkdir -p "$target"
fi
""",
        encoding="utf-8",
    )
    git.chmod(0o755)

    git_log = tmp_path / "git.log"
    env = os.environ.copy()
    env.update({
        "PATH": f"{fake_bin}:{env['PATH']}",
        "GITLAB_TOKEN": "fixture-token",
        "FAKE_FIXTURES": str(fixtures),
        "FAKE_GIT_LOG": str(git_log),
    })
    env.update(overrides)
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    return result, git_log.read_text(encoding="utf-8") if git_log.exists() else ""


def test_discovers_projects_across_full_page_boundary(tmp_path: Path) -> None:
    first = [project(i, name="project with spaces" if i == 0 else None) for i in range(100)]
    second = [project(100)]
    result, git_log = harness(tmp_path, {1: first, 2: second})

    assert result.returncode == 0, result.stderr
    assert "Validated 101 mirror project records" in result.stderr
    assert "synced: 101 | skipped: 0 | failed: 0" in result.stderr
    assert len(git_log.splitlines()) == 202
    assert "project with spaces" in result.stderr


def test_empty_group_is_successful_and_performs_no_git_operations(tmp_path: Path) -> None:
    result, git_log = harness(tmp_path, {1: []})

    assert result.returncode == 0, result.stderr
    assert "Validated 0 mirror project records" in result.stderr
    assert git_log == ""


@pytest.mark.parametrize(
    ("pages", "overrides", "expected"),
    [
        ({1: [{"id": 1, "name": "missing destination", "import_url": ""}]}, {}, "http_url_to_repo"),
        ({1: {"not": "an array"}}, {}, "expected a JSON array"),
        ({1: [project(1)]}, {"FAKE_HTTP_ERROR_PAGE": "1"}, "HTTP 500"),
        ({1: [project(1)]}, {"FAKE_TRANSPORT_FAIL_PAGE": "1"}, "transport failed"),
        ({1: [project(1)], 2: {"bad": "page"}}, {}, "expected a JSON array"),
    ],
)
def test_invalid_or_failed_listing_stops_before_any_git_operation(
    tmp_path: Path,
    pages: dict[int, object],
    overrides: dict[str, str],
    expected: str,
) -> None:
    result, git_log = harness(tmp_path, pages, **overrides)

    assert result.returncode != 0
    assert expected in result.stderr
    assert git_log == ""
