import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTTP_TEST = ROOT / "scripts/tests/test-platform-adapter-http-classification.sh"


def test_platform_adapter_http_classification() -> None:
    result = subprocess.run(
        ["bash", str(HTTP_TEST)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "platform adapter HTTP classification: ok" in result.stdout
