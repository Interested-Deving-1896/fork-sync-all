"""Tests for bounded retry handling in the README Models helper."""

import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "includes" / "readme-llm.sh"


def run_llm(tmp_path: Path, codes: str, retry_after: str):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    counter, sleeps = tmp_path / "curl-count", tmp_path / "sleep-log"
    curl = fake_bin / "curl"
    curl.write_text("""#!/usr/bin/env bash
headers=""
while (($#)); do
  if [[ "$1" == "-D" ]]; then headers="$2"; shift 2; else shift; fi
done
count=$(cat "$MOCK_COUNTER" 2>/dev/null || echo 0)
count=$((count + 1)); printf '%s' "$count" > "$MOCK_COUNTER"
status=$(printf '%s' "$MOCK_CODES" | cut -d, -f "$count")
[[ -n "$status" ]] || status=000
printf 'HTTP/1.1 %s Mock\\n' "$status" > "$headers"
if [[ "$status" == "429" ]]; then printf 'Retry-After: %s\\n' "$MOCK_RETRY_AFTER" >> "$headers"; fi
if [[ "$status" == "000" ]]; then printf '%s\\n' "$status"; exit 7; fi
if [[ "$status" == "200" ]]; then
  printf '%s\\n%s\\n' '{"choices":[{"message":{"content":"safe response"}}]}' "$status"
else
  printf '%s\\n%s\\n' '{"error":"suppressed"}' "$status"
fi
""", encoding="utf-8")
    curl.chmod(0o755)
    sleep = fake_bin / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$1\" >> \"$MOCK_SLEEP_LOG\"\n", encoding="utf-8")
    sleep.chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
           "GH_TOKEN": "test-token", "MODEL": "test-model", "MODELS_API": "https://models.invalid",
           "MOCK_CODES": codes, "MOCK_RETRY_AFTER": retry_after,
           "MOCK_COUNTER": str(counter), "MOCK_SLEEP_LOG": str(sleeps)}
    result = subprocess.run(["bash", "-c", 'source "$1"; warn(){ echo "[test-warn] $*" >&2; }; llm_ask "system" "user"', "_", str(HELPER)],
                           env=env, capture_output=True, text=True, timeout=10, check=False)
    return result, counter, sleeps


def test_429_honors_retry_after_then_succeeds(tmp_path: Path) -> None:
    result, counter, sleeps = run_llm(tmp_path, "429,200", "7")
    assert result.returncode == 0
    assert result.stdout.strip() == "safe response"
    assert counter.read_text() == "2"
    assert sleeps.read_text().splitlines() == ["7"]


def test_retry_after_is_capped_and_retries_are_bounded(tmp_path: Path) -> None:
    result, counter, sleeps = run_llm(tmp_path, "429,429,429,429", "9999")
    assert result.returncode == 0
    assert result.stdout.strip() == ""
    assert counter.read_text() == "4"
    assert sleeps.read_text().splitlines() == ["900", "900", "900"]
    assert "persisted after 3 retries" in result.stderr
    assert "capping wait" in result.stderr


def test_transport_failure_retries_then_succeeds(tmp_path: Path) -> None:
    result, counter, sleeps = run_llm(tmp_path, "000,200", "7")
    assert result.returncode == 0
    assert result.stdout.strip() == "safe response"
    assert counter.read_text() == "2"
    assert sleeps.read_text().splitlines() == ["5"]
    assert "transport failure" in result.stderr


def test_transport_failure_retries_are_bounded(tmp_path: Path) -> None:
    result, counter, sleeps = run_llm(tmp_path, "000,000,000,000", "7")
    assert result.returncode == 0
    assert result.stdout.strip() == ""
    assert counter.read_text() == "4"
    assert sleeps.read_text().splitlines() == ["5", "10", "15"]
    assert "persisted after 3 retries" in result.stderr
    assert "suppressed" not in result.stderr
