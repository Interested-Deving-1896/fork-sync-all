import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUOTA_TEST = ROOT / "scripts/tests/test-fsa-adapter-quota-fail-closed.sh"


def test_fsa_adapter_unknown_quota_fails_closed() -> None:
    result = subprocess.run(
        ["bash", str(QUOTA_TEST)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "FSA adapter quota fail-closed behavior: ok" in result.stdout
