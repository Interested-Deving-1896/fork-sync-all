import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/hw-detect-ci.yml"


def test_hw_detect_json_matches_nested_ci_contract() -> None:
    result = subprocess.run(
        ["bash", "scripts/hw-detect.sh", "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)

    assert payload["cpu"]["cpu_arch"]
    assert payload["cpu"]["cpu_tier"]
    assert payload["gpu"]["gpu_tier"]
    assert payload["npu"]["npu_tier"]


def test_hw_detect_workflow_validates_nested_detector_output() -> None:
    workflow = WORKFLOW.read_text()

    assert "push:\n    branches:\n      - main" in workflow
    assert "d.get('cpu', {}).get('cpu_arch')" in workflow
    assert "d.get('cpu', {}).get('cpu_tier')" in workflow
    assert "d.get('gpu', {}).get('gpu_tier')" in workflow
    assert "d.get('npu', {}).get('npu_tier')" in workflow
    assert "['CPU_ARCH','CPU_TIER','GPU_TIER','NPU_TIER']" not in workflow
    assert 'for key in KPORT_ARCH KPORT_CFLAGS KPORT_CMAKE_ARGS' in workflow
    assert "apt-get install -y -qq python3" in workflow


def test_hw_build_env_json_contains_the_fields_ci_requires() -> None:
    result = subprocess.run(
        ["bash", "scripts/hw-build-env.sh", "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    required = {
        "CPU_TIER",
        "GPU_TIER",
        "NPU_TIER",
        "KPORT_ARCH",
        "KPORT_CFLAGS",
        "KPORT_CMAKE_ARGS",
        "KPORT_MAKE_ARGS",
        "KPORT_GPU_BACKEND",
        "KPORT_NPU_BACKEND",
    }

    assert all(payload.get(key) for key in required)


def test_hw_build_env_export_is_nonempty_and_eval_safe() -> None:
    command = (
        'set -e; eval "$(bash scripts/hw-build-env.sh --export 2>/dev/null)"; '
        'test -n "$KPORT_ARCH"; test -n "$KPORT_CMAKE_ARGS"; '
        'test -n "$KPORT_MAKE_ARGS"'
    )

    subprocess.run(["bash", "-c", command], cwd=ROOT, check=True)


def test_build_flags_cross_argument_selects_requested_architecture() -> None:
    result = subprocess.run(
        [
            "bash",
            "scripts/kport/kport-build-flags.sh",
            "--json",
            "--cross",
            "arm64",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)

    assert payload["KPORT_ARCH"] == "arm64"
    assert payload["KPORT_CROSS"] == "true"
    assert payload["KPORT_CROSS_TRIPLE"] == "aarch64-linux-gnu"


def test_hw_build_env_json_forwards_cross_target() -> None:
    result = subprocess.run(
        ["bash", "scripts/hw-build-env.sh", "--json", "--cross", "arm64"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)

    assert payload["KPORT_ARCH"] == "arm64"
    assert payload["KPORT_CROSS"] == "true"
    assert payload["KPORT_CROSS_TRIPLE"] == "aarch64-linux-gnu"
