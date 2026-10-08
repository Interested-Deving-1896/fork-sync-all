"""End-to-end blocking tests for post-flush verification with a fake API."""

import os
from pathlib import Path
import subprocess
import textwrap

import yaml


ROOT = Path(__file__).resolve().parents[1]


def _first_osp_repo() -> str:
    config = yaml.safe_load((ROOT / "config/gitlab-subgroups.yml").read_text())
    for subgroup in config["subgroups"].values():
        repos = subgroup.get("repos") or []
        if repos:
            return repos[0]
    raise AssertionError("gitlab-subgroups.yml contains no repositories")


def _fake_curl(tmp_path: Path) -> Path:
    curl = tmp_path / "curl"
    curl.write_text(
        textwrap.dedent(
            r"""\
            #!/usr/bin/env bash
            set -u
            url=""
            wants_status=false
            for arg in "$@"; do
              [[ "$arg" == http://* || "$arg" == https://* ]] && url="$arg"
              [[ "$arg" == *'%{http_code}'* ]] && wants_status=true
            done

            case "$url" in
              */rate_limit)
                body='{"resources":{"core":{"remaining":5000,"reset":4102444800}}}'
                ;;
              *gitlab.com/api/v4/*/repository/commits*)
                body='[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
                ;;
              */check-runs*)
                if [[ "${FAKE_CI_FAILURE:-false}" == "true" ]]; then
                  body='{"check_runs":[{"name":"ci","status":"completed","conclusion":"failure"}]}'
                elif [[ "${FAKE_CI_PENDING:-false}" == "true" ]]; then
                  body='{"check_runs":[{"name":"ci","status":"in_progress","conclusion":null}]}'
                else
                  body='{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}'
                fi
                ;;
              */commits/HEAD)
                body='{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
                ;;
              *'/actions/runs?'*)
                body='{"total_count":0,"workflow_runs":[]}'
                ;;
              *)
                body='{}'
                ;;
            esac

            if [[ "$wants_status" == "true" ]]; then
              printf '%s\n200' "$body"
            else
              printf '%s' "$body"
            fi
            """
        )
    )
    curl.chmod(0o755)
    return curl


def _run_post_flush(
    tmp_path: Path, *, ci_failure: bool = False, ci_pending: bool = False
) -> subprocess.CompletedProcess[str]:
    _fake_curl(tmp_path)
    env = {
        **os.environ,
        "PATH": f"{tmp_path}:{os.environ['PATH']}",
        "GH_TOKEN": "fake",
        "GITLAB_TOKEN": "fake",
        "REPO": "owner/repo",
        "REPO_FILTER": _first_osp_repo(),
        "BLOCK_ON_FAILURE": "true",
        "MIN_QUOTA": "1",
        "BUDGET_MINUTES": "5",
        "FAKE_CI_FAILURE": "true" if ci_failure else "false",
        "FAKE_CI_PENDING": "true" if ci_pending else "false",
    }
    return subprocess.run(
        ["bash", str(ROOT / "scripts/post-flush-prep.sh")],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_blocking_post_flush_succeeds_when_integrity_and_ci_are_healthy(tmp_path: Path):
    result = _run_post_flush(tmp_path, ci_failure=False)
    assert result.returncode == 0, result.stderr


def test_blocking_post_flush_fails_when_ci_is_red(tmp_path: Path):
    result = _run_post_flush(tmp_path, ci_failure=True)
    assert result.returncode == 1
    assert "critical failure" in result.stderr.lower()


def test_blocking_post_flush_fails_when_ci_is_still_pending(tmp_path: Path):
    result = _run_post_flush(tmp_path, ci_pending=True)
    assert result.returncode == 1
    assert "unverified" in result.stderr.lower()
