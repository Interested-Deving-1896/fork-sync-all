"""Regression tests for semantic validation in scripts/includes/gh-api.sh."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "includes" / "gh-api.sh"


def run_helper(tmp_path: Path, command: str, *, response: str = "", status: int = 0) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["GH_TOKEN"] = "test-token"
    env["GH_API_STUB_RESPONSE"] = response
    env["GH_API_STUB_STATUS"] = str(status)
    script = f"""
source "{HELPER}"
gh_api() {{
  printf '%s' "$GH_API_STUB_RESPONSE"
  return "$GH_API_STUB_STATUS"
}}
{command}
"""
    return subprocess.run(
        ["bash", "-c", script],
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def test_get_default_sha_preserves_api_failure(tmp_path: Path) -> None:
    result = run_helper(tmp_path, 'get_default_sha "owner/repo" "main"', status=7)

    assert result.returncode != 0
    assert result.stdout == ""


def test_get_default_sha_rejects_missing_sha(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        'get_default_sha "owner/repo" "main"',
        response='{"object":{}}',
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "invalid Git ref response" in result.stderr


def test_graphql_errors_array_is_not_success(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        "gh_api_graphql 'query { viewer { login } }'",
        response='{"errors":[{"message":"denied"}]}',
    )

    assert result.returncode != 0
    assert "GraphQL response contains errors" in result.stderr


def test_graphql_success_returns_original_json(tmp_path: Path) -> None:
    response = '{"data":{"viewer":{"login":"example"}}}'
    result = run_helper(
        tmp_path,
        "gh_api_graphql 'query { viewer { login } }'",
        response=response,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == response


def test_merge_upstream_does_not_ignore_api_failure(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        'merge_upstream "owner/repo" "main"',
        response='{"merge_type":"merge"}',
        status=1,
    )

    assert result.returncode != 0
    assert "merge request failed" in result.stderr
    assert "merged:" not in result.stderr


def test_merge_upstream_rejects_malformed_success_body(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        'merge_upstream "owner/repo" "main"',
        response='not-json',
    )

    assert result.returncode != 0
    assert "merge failed" in result.stderr
    assert "merged:" not in result.stderr

def test_graphql_non_object_json_is_not_success(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        "gh_api_graphql 'query { viewer { login } }'",
        response='["unexpected"]',
    )

    assert result.returncode != 0
    assert "GraphQL response contains errors" in result.stderr

def test_get_default_sha_returns_sha_with_newline(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        'get_default_sha "owner/repo" "main"',
        response='{"object":{"sha":"0123456789abcdef"}}',
    )

    assert result.returncode == 0
    assert result.stdout == "0123456789abcdef\n"

def test_graphql_object_without_data_or_errors_is_not_success(tmp_path: Path) -> None:
    result = run_helper(
        tmp_path,
        "gh_api_graphql 'query { viewer { login } }'",
        response='{"message":"unexpected response"}',
    )

    assert result.returncode != 0
    assert "GraphQL response contains errors" in result.stderr

