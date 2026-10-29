"""Regression tests for fail-closed runner-status observation reporting."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "runner-status.sh"


def test_quota_skip_is_not_reported_as_healthy():
    source = SCRIPT.read_text(encoding="utf-8")
    quota_branch = source.split('if [[ "$remaining" -lt "$MIN_QUOTA" ]]; then', 1)[1].split(
        "# ── Probe org endpoint", 1
    )[0]

    assert 'echo "healthy=false"' in quota_branch
    assert 'echo "observation_status=unknown"' in quota_branch
    assert 'echo "healthy=true"' not in quota_branch


def test_unavailable_org_endpoint_is_not_reported_as_healthy():
    source = SCRIPT.read_text(encoding="utf-8")
    unavailable_branch = source.split('if [[ "$probe_code" != "200" ]]; then', 1)[1].split(
        "# ── Fetch runs via org endpoint", 1
    )[0]

    assert 'echo "healthy=false"' in unavailable_branch
    assert 'echo "observation_status=unknown"' in unavailable_branch
    assert 'echo "healthy=true"' not in unavailable_branch


def test_successful_observation_is_explicitly_marked():
    source = SCRIPT.read_text(encoding="utf-8")

    assert 'echo "observation_status=observed"' in source
