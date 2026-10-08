import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CAPACITY_TEST = ROOT / "scripts/tests/test-platform-adapter-capacity.sh"


def test_platform_adapter_capacity_contract() -> None:
    result = subprocess.run(
        ["bash", str(CAPACITY_TEST)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "platform-adapter capacity discovery: ok" in result.stdout

