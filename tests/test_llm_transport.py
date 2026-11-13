"""Transport configuration tests for scripts/includes/llm.sh.

All HTTP calls use a fake curl executable; these tests never access a provider.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LLM_SH = ROOT / "scripts" / "includes" / "llm.sh"
SUCCESS_BODY = '{"choices":[{"message":{"content":"ok"}}]}'


def invoke_llm(tmp_path: Path, extra_env: dict[str, str] | None = None):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    capture = tmp_path / "curl-args"
    curl = bin_dir / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'%s\\n\' "$@" > "$MOCK_CAPTURE"\n'
        'printf \'%s\\n\' "$MOCK_BODY"\n'
        'printf \'%s\\n\' "$MOCK_STATUS"\n',
        encoding="utf-8",
    )
    curl.chmod(0o755)

    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
        "GH_TOKEN": "fallback-token",
        "MODEL": "test-model",
        "MOCK_BODY": SUCCESS_BODY,
        "MOCK_STATUS": "200",
        "MOCK_CAPTURE": str(capture),
    })
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        ["bash", "-c", 'source "$1"; llm_call "system" "user"',
         "_", str(LLM_SH)],
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )
    args = capture.read_text(encoding="utf-8") if capture.exists() else ""
    return result, args


def test_default_endpoint_and_gh_token_fallback(tmp_path: Path) -> None:
    result, args = invoke_llm(tmp_path)

    assert result.returncode == 0
    assert "https://models.github.ai/inference/chat/completions" in args
    assert "Bearer fallback-token" in args


def test_custom_https_endpoint_and_api_key_override(tmp_path: Path) -> None:
    result, args = invoke_llm(tmp_path, {
        "LLM_API_BASE_URL": "https://inference.example.test/v1/",
        "LLM_API_KEY": "custom-provider-token",
    })

    assert result.returncode == 0
    assert "https://inference.example.test/v1/chat/completions" in args
    assert "Bearer custom-provider-token" in args
    assert "Bearer fallback-token" not in args


def test_non_https_endpoint_is_rejected_before_curl(tmp_path: Path) -> None:
    result, args = invoke_llm(tmp_path, {
        "LLM_API_BASE_URL": "http://inference.example.test/v1",
        "LLM_API_KEY": "custom-provider-token",
    })

    assert result.returncode != 0
    assert "LLM_API_BASE_URL must use HTTPS" in result.stderr
    assert args == ""
