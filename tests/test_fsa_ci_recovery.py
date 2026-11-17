import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/fsa_ci_recovery.py"


def load_module():
    spec = importlib.util.spec_from_file_location("fsa_ci_recovery", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_failure_classification_preserves_unknown_and_conflicts():
    module = load_module()
    assert module.classify_failure({"network_transport": True})["classification"] == "network_transport"
    assert module.classify_failure({})["classification"] == "unknown"
    assert module.classify_failure({
        "network_transport": True, "runner_host": True
    })["confidence"] == "conflicting"


def test_retry_policy_suppresses_non_idempotent_and_saturated_work():
    module = load_module()
    assert module.retry_decision(
        attempt=0, max_attempts=3, retryable=True, idempotent=False, saturated=False
    )["decision"] == "suppress"
    assert module.retry_decision(
        attempt=0, max_attempts=3, retryable=True, idempotent=True, saturated=True
    )["reason"] == "capacity_saturated"


def test_retry_policy_is_bounded_and_honors_retry_after():
    module = load_module()
    result = module.retry_decision(
        attempt=2, max_attempts=4, retryable=True, idempotent=True,
        saturated=False, base_delay_seconds=10, max_delay_seconds=60,
        retry_after_seconds=90, jitter_fraction=0.1,
    )
    assert result["decision"] == "defer"
    assert result["reason"] == "retry_after_exceeds_local_delay_window"
    assert result["delay_seconds"] == 90
    bounded = module.retry_decision(
        attempt=2, max_attempts=4, retryable=True, idempotent=True,
        saturated=False, base_delay_seconds=10, max_delay_seconds=60,
        retry_after_seconds=55, jitter_fraction=0.1,
    )
    assert bounded["decision"] == "retry"
    assert bounded["delay_seconds"] == 60
    assert module.retry_decision(
        attempt=3, max_attempts=3, retryable=True, idempotent=True, saturated=False
    )["reason"] == "retry_budget_exhausted"


def test_shard_integrity_requires_exact_unique_set():
    module = load_module()
    assert module.shard_integrity(["a", "b"], ["b", "a"])["complete"] is True
    result = module.shard_integrity(["a", "b"], ["a", "a", "c"])
    assert result["complete"] is False
    assert result["missing"] == ["b"]
    assert result["duplicates"] == ["a"]
    assert result["unexpected"] == ["c"]


def test_failover_requires_all_declared_capabilities():
    module = load_module()
    assert module.capability_compatibility(
        {"os": "macos", "arch": "arm64", "sdk": ["ios", "xcode"]},
        {"os": "macos", "arch": "arm64", "sdk": ["ios", "xcode", "swift"]},
    )["compatible"] is True
    assert module.capability_compatibility(
        {"os": "macos"}, {"os": "linux"}
    )["compatible"] is False


def test_recovery_requires_fresh_independent_evidence():
    module = load_module()
    assert module.recovery_verification({"provider_status_only": True})["verified"] is False
    evidence = {
        "fresh": True,
        "provider_connectivity": True,
        "runner_readiness": True,
        "queue_stable": True,
        "task_initialization": True,
        "shards_complete": True,
        "canary_success": True,
    }
    assert module.recovery_verification(evidence)["state"] == "recovered"
