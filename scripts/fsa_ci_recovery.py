"""Offline, provider-neutral CI incident and recovery policy primitives.

This module deliberately performs no network, runner, queue, or provider actions.
Callers must treat its outputs as plans/evidence, not authorization.
"""
from __future__ import annotations

from typing import Any, Iterable

FAILURE_CLASSES = (
    "infrastructure_capacity",
    "quota_rate_limit",
    "network_transport",
    "runner_host",
    "scheduler_queue",
    "test_harness",
    "code_test",
    "unknown",
)


def classify_failure(signals: dict[str, Any]) -> dict[str, Any]:
    """Classify only explicit, affirmative evidence; conflicting evidence is unknown."""
    keys = FAILURE_CLASSES[:-1]
    confirmed = [key for key in keys if signals.get(key) is True]
    unknown_inputs = [
        key for key in keys
        if key not in signals or signals.get(key) is None
    ]
    if len(confirmed) == 1:
        classification = confirmed[0]
        confidence = "high" if not unknown_inputs else "provisional"
        rationale = "one failure class has affirmative evidence"
    elif len(confirmed) > 1:
        classification, confidence = "unknown", "conflicting"
        rationale = "multiple failure classes have affirmative evidence"
    else:
        classification, confidence = "unknown", "unverified"
        rationale = "no failure class has affirmative evidence"
    return {
        "classification": classification,
        "confidence": confidence,
        "evidence": confirmed,
        "unknown_inputs": unknown_inputs,
        "rationale": rationale,
    }


def retry_decision(
    *,
    attempt: int,
    max_attempts: int,
    retryable: bool,
    idempotent: bool,
    saturated: bool,
    base_delay_seconds: float = 30,
    max_delay_seconds: float = 900,
    retry_after_seconds: float | None = None,
    jitter_fraction: float = 0,
) -> dict[str, Any]:
    """Return a bounded retry plan; never execute a retry."""
    if attempt < 0 or max_attempts < 1:
        raise ValueError("attempt must be >= 0 and max_attempts must be >= 1")
    if base_delay_seconds < 0 or max_delay_seconds < 0:
        raise ValueError("retry delays must be non-negative")
    if not 0 <= jitter_fraction <= 1:
        raise ValueError("jitter_fraction must be between 0 and 1")
    if retry_after_seconds is not None and retry_after_seconds < 0:
        raise ValueError("retry_after_seconds must be non-negative")
    reason = None
    if not retryable:
        reason = "failure_not_retryable"
    elif not idempotent:
        reason = "operation_not_idempotent"
    elif attempt >= max_attempts:
        reason = "retry_budget_exhausted"
    elif saturated:
        reason = "capacity_saturated"
    if reason:
        return {"decision": "suppress", "reason": reason, "delay_seconds": None}
    if retry_after_seconds is not None and retry_after_seconds > max_delay_seconds:
        return {
            "decision": "defer",
            "reason": "retry_after_exceeds_local_delay_window",
            "delay_seconds": round(retry_after_seconds, 3),
        }
    exponential = min(max_delay_seconds, base_delay_seconds * (2 ** attempt))
    requested = max(exponential, retry_after_seconds or 0)
    delay = min(max_delay_seconds, requested * (1 + jitter_fraction))
    return {
        "decision": "retry",
        "reason": "within_budget_and_capacity_available",
        "delay_seconds": round(delay, 3),
    }


def shard_integrity(expected: Iterable[str], observed: Iterable[str]) -> dict[str, Any]:
    """Require a unique, exact set of non-empty shard identifiers."""
    expected_list, observed_list = list(expected), list(observed)
    invalid = any(
        not isinstance(item, str) or not item
        for item in expected_list + observed_list
    )
    if invalid:
        return {
            "complete": False,
            "expected_count": len(expected_list),
            "observed_count": len(observed_list),
            "missing": [],
            "unexpected": [],
            "duplicates": [],
            "invalid_identifiers": True,
        }
    expected_set, observed_set = set(expected_list), set(observed_list)
    counts = {item: observed_list.count(item) for item in observed_set}
    duplicates = sorted(item for item, count in counts.items() if count > 1)
    missing = sorted(expected_set - observed_set)
    unexpected = sorted(observed_set - expected_set)
    complete = (
        len(expected_set) == len(expected_list)
        and not duplicates and not missing and not unexpected
    )
    return {
        "complete": complete,
        "expected_count": len(expected_list),
        "observed_count": len(observed_list),
        "missing": missing,
        "unexpected": unexpected,
        "duplicates": duplicates,
        "invalid_identifiers": invalid,
    }


def capability_compatibility(
    requirements: dict[str, Any], candidate: dict[str, Any]
) -> dict[str, Any]:
    """A candidate is compatible only when every declared requirement matches."""
    mismatches = {}
    for key, required in requirements.items():
        actual = candidate.get(key)
        if isinstance(required, list):
            if not isinstance(actual, list) or not set(required).issubset(set(actual)):
                mismatches[key] = {"required": required, "actual": actual}
        elif actual != required:
            mismatches[key] = {"required": required, "actual": actual}
    return {"compatible": not mismatches, "mismatches": mismatches}


def recovery_verification(evidence: dict[str, Any]) -> dict[str, Any]:
    """Require fresh independent signals; provider status alone cannot prove recovery."""
    required = (
        "provider_connectivity",
        "runner_readiness",
        "queue_stable",
        "task_initialization",
        "shards_complete",
        "canary_success",
    )
    missing = [key for key in required if evidence.get(key) is not True]
    fresh = evidence.get("fresh") is True
    verified = not missing and fresh
    return {
        "state": "recovered" if verified else "unknown",
        "verified": verified,
        "missing_or_failed_evidence": missing,
        "fresh_evidence": fresh,
        "provider_status_only": evidence.get("provider_status_only") is True,
        "reason": (
            "all independent recovery checks passed"
            if verified
            else "independent fresh recovery evidence is incomplete"
        ),
    }
