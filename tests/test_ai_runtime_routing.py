from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ai_runtime_routing import BackendEvidence, WorkloadRequest, route_workload


NOW = datetime(2026, 11, 5, 20, 0, tzinfo=timezone.utc)
STAMP = NOW.isoformat().replace("+00:00", "Z")


def evidence(**changes):
    values = {
        "backend_id": "cuda",
        "state": "verified-usable",
        "observed_at": STAMP,
        "source": "test-adapter",
        "workloads": frozenset({"llm-inference"}),
        "data_types": frozenset({"float16", "float32"}),
        "device_memory_bytes": 8 * 1024**3,
    }
    values.update(changes)
    return BackendEvidence(**values)


def test_verified_fresh_evidence_routes_to_accelerator():
    decision = route_workload(
        WorkloadRequest("llm-inference", "float16", 4 * 1024**3),
        [evidence()], now=NOW,
    )
    assert decision.backend_id == "cuda"
    assert decision.evidence_source == "test-adapter"


def test_candidate_presence_never_routes_to_accelerator():
    decision = route_workload(
        WorkloadRequest("llm-inference"),
        [evidence(state="candidate")], now=NOW,
    )
    assert decision.backend_id == "cpu"


def test_stale_or_future_evidence_is_rejected():
    stale = (NOW - timedelta(seconds=301)).isoformat().replace("+00:00", "Z")
    future = (NOW + timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
    for stamp in (stale, future):
        decision = route_workload(
            WorkloadRequest("llm-inference"), [evidence(observed_at=stamp)], now=NOW,
        )
        assert decision.backend_id == "cpu"


def test_unknown_workload_dtype_or_memory_denies_acceleration():
    for request in (
        WorkloadRequest("image-generation"),
        WorkloadRequest("llm-inference", "int8"),
        WorkloadRequest("llm-inference", min_device_memory_bytes=16 * 1024**3),
    ):
        assert route_workload(request, [evidence()], now=NOW).backend_id == "cpu"


def test_cpu_fallback_can_be_disabled():
    decision = route_workload(
        WorkloadRequest("llm-inference", allow_cpu_fallback=False),
        [], now=NOW,
    )
    assert decision.backend_id == "unavailable"


def test_timestamp_must_be_timezone_aware():
    try:
        evidence(observed_at="2026-11-05T20:00:00")
    except ValueError as exc:
        assert "timezone" in str(exc)
    else:
        raise AssertionError("naive timestamp accepted")


def test_unknown_backend_state_is_rejected():
    try:
        evidence(state="probably-works")
    except ValueError as exc:
        assert "state" in str(exc)
    else:
        raise AssertionError("unknown state accepted")
