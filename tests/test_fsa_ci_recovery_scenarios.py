import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/fsa_ci_recovery.py"


def load_module():
    spec = importlib.util.spec_from_file_location("fsa_ci_recovery", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeProvider:
    """Deterministic incident fixture; no network or provider API is contacted."""

    def __init__(self, **state):
        self.state = state

    def observe(self):
        return dict(self.state)


def test_datacenter_outage_suppresses_retry_and_incompatible_failover():
    policy = load_module()
    provider = FakeProvider(
        infrastructure_capacity=True,
        saturated=True,
        expected_shards=["macos-1", "macos-2", "ios-1"],
        observed_shards=["macos-1", "ios-1"],
        requirements={"os": "macos", "arch": "arm64", "sdk": ["xcode", "ios"]},
        candidate={"os": "linux", "arch": "arm64", "sdk": ["linux"]},
        evidence={"provider_status_only": True},
    ).observe()

    classification = policy.classify_failure({
        "infrastructure_capacity": provider["infrastructure_capacity"]
    })
    retry = policy.retry_decision(
        attempt=0, max_attempts=4, retryable=True, idempotent=True,
        saturated=provider["saturated"],
    )
    failover = policy.capability_compatibility(
        provider["requirements"], provider["candidate"]
    )
    shards = policy.shard_integrity(
        provider["expected_shards"], provider["observed_shards"]
    )
    recovery = policy.recovery_verification(provider["evidence"])

    assert classification["classification"] == "infrastructure_capacity"
    assert retry["reason"] == "capacity_saturated"
    assert failover["compatible"] is False
    assert shards["complete"] is False
    assert shards["missing"] == ["macos-2"]
    assert recovery["state"] == "unknown"


def test_provider_green_without_runner_and_canary_evidence_is_not_recovery():
    policy = load_module()
    provider = FakeProvider(
        evidence={
            "provider_status_only": True,
            "fresh": True,
            "provider_connectivity": True,
            "runner_readiness": False,
            "queue_stable": True,
            "task_initialization": False,
            "shards_complete": True,
            "canary_success": False,
        }
    ).observe()
    result = policy.recovery_verification(provider["evidence"])
    assert result["state"] == "unknown"
    assert result["missing_or_failed_evidence"] == [
        "runner_readiness", "task_initialization", "canary_success"
    ]


def test_recovered_provider_requires_all_fresh_checks_and_complete_shards():
    policy = load_module()
    provider = FakeProvider(
        expected_shards=["a", "b"],
        observed_shards=["b", "a"],
        evidence={
            "fresh": True,
            "provider_connectivity": True,
            "runner_readiness": True,
            "queue_stable": True,
            "task_initialization": True,
            "shards_complete": True,
            "canary_success": True,
        },
    ).observe()
    shards = policy.shard_integrity(
        provider["expected_shards"], provider["observed_shards"]
    )
    evidence = dict(provider["evidence"], shards_complete=shards["complete"])
    assert policy.recovery_verification(evidence)["state"] == "recovered"
