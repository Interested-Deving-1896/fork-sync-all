"""Regression tests for safe diagnostics from scripts/includes/llm.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parent.parent
LLM_SH = REPO_ROOT / "scripts" / "includes" / "llm.sh"


def run_llm_call(tmp_path: Path, body: str, status: str) -> subprocess.CompletedProcess[str]:
    """Run llm_call with deterministic fake curl/sleep commands; never hit the network."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$MOCK_BODY\"\n"
        "printf '%s\\n' \"$MOCK_STATUS\"\n",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    sleep = bin_dir / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    sleep.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
            "GH_TOKEN": "test-token",
            "MODEL": "test-model",
            "MOCK_BODY": body,
            "MOCK_STATUS": status,
        }
    )
    return subprocess.run(
        ["bash", "-c", 'source "$1"; llm_call "system" "user"', "_", str(LLM_SH)],
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )


def test_http_error_does_not_log_provider_response_body(tmp_path: Path) -> None:
    secret_body = '{"error":"provider echoed confidential request content"}'

    result = run_llm_call(tmp_path, secret_body, "401")

    assert result.returncode != 0
    assert "HTTP 401" in result.stderr
    assert "response body suppressed" in result.stderr
    assert "confidential request content" not in result.stdout
    assert "confidential request content" not in result.stderr


def test_malformed_http_200_has_safe_diagnostic(tmp_path: Path) -> None:
    result = run_llm_call(tmp_path, "not-json", "200")

    assert result.returncode != 0
    assert "HTTP 200 response was not valid JSON" in result.stderr
    assert "not-json" not in result.stderr


def test_valid_http_200_returns_message_content(tmp_path: Path) -> None:
    result = run_llm_call(
        tmp_path,
        '{"choices":[{"message":{"content":"Ciao mondo"}}]}',
        "200",
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "Ciao mondo"
    assert result.stderr == ""
