"""Contract tests for shared GitHub API wrapper helpers."""

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "includes" / "gh-api.sh"


def _run_helper(command: str, *, api_body: str = "", api_status: str = "0") -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["GH_TOKEN"] = "test-token"
    env["MOCK_API_BODY"] = api_body
    env["MOCK_API_STATUS"] = api_status
    script = f"""
source "{HELPER}"
gh_api() {{
  printf '%s' "$MOCK_API_BODY"
  return "$MOCK_API_STATUS"
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


def test_get_default_sha_propagates_api_failure() -> None:
    result = _run_helper('get_default_sha "owner/repo" "main"', api_status="1")

    assert result.returncode != 0
    assert result.stdout.strip() == ""


def test_get_default_sha_rejects_missing_sha() -> None:
    result = _run_helper(
        'get_default_sha "owner/repo" "main"',
        api_body='{"object":{}}',
    )

    assert result.returncode != 0
    assert result.stdout.strip() == ""


def test_get_default_sha_returns_valid_sha() -> None:
    sha = "0123456789abcdef0123456789abcdef01234567"
    result = _run_helper(
        'get_default_sha "owner/repo" "main"',
        api_body=f'{{"object":{{"sha":"{sha}"}}}}',
    )

    assert result.returncode == 0
    assert result.stdout.strip() == sha

def test_get_default_sha_rejects_malformed_nonempty_sha_values() -> None:
    malformed_values = [
        "not-a-sha",
        "0123456789abcdef",
        "g123456789abcdef0123456789abcdef01234567",
        "0123456789abcdef0123456789abcdef012345678",
    ]
    for sha in malformed_values:
        result = _run_helper(
            'get_default_sha "owner/repo" "main"',
            api_body=f'{{"object":{{"sha":"{sha}"}}}}',
        )
        assert result.returncode != 0, f"accepted malformed SHA: {sha}"
        assert result.stdout.strip() == ""


def test_graphql_rejects_http_success_with_application_errors() -> None:
    result = _run_helper(
        'gh_api_graphql "query { viewer { login } }"',
        api_body='{"data":null,"errors":[{"message":"permission denied"}]}',
    )

    assert result.returncode != 0
    assert "GraphQL returned application errors" in result.stderr
    assert "permission denied" in result.stderr
    assert result.stdout.strip() == ""


def test_graphql_rejects_invalid_json() -> None:
    result = _run_helper(
        'gh_api_graphql "query { viewer { login } }"',
        api_body="not-json",
    )

    assert result.returncode != 0
    assert "not valid JSON" in result.stderr


def test_graphql_returns_valid_response_without_errors() -> None:
    body = '{"data":{"viewer":{"login":"test-user"}}}'
    result = _run_helper(
        'gh_api_graphql "query { viewer { login } }"',
        api_body=body,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == body


def test_merge_upstream_rejects_malformed_success_body() -> None:
    result = _run_helper(
        'merge_upstream "owner/repo" "main"',
        api_body="not-json",
    )

    assert result.returncode != 0
    assert "merge failed" in result.stderr
