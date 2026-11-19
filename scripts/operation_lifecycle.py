"""Deterministic, provider-neutral operation preflight and postflight evaluators.
Offline and side-effect free: adapters collect evidence; this module evaluates it.
"""
from __future__ import annotations
from datetime import datetime, timezone
from typing import Any, Mapping
import hashlib
import json

SCHEMA_VERSION = "1.0"
EVIDENCE_STATES = {"declared", "observed", "inferred", "human_approved", "contradicted", "stale", "incomplete", "inaccessible", "unknown"}

class ContractError(ValueError):
    """An operation or evidence envelope violates the public contract."""

def _nonempty(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{field} must be a non-empty string")
    return value.strip()

def _unique_strings(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(x, str) or not x.strip() for x in value):
        raise ContractError(f"{field} must be an array of non-empty strings")
    cleaned = [x.strip() for x in value]
    if len(set(cleaned)) != len(cleaned):
        raise ContractError(f"{field} must not contain duplicates")
    return cleaned

def validate_operation(operation: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(operation, Mapping):
        raise ContractError("operation must be an object")
    if operation.get("schema_version") != SCHEMA_VERSION:
        raise ContractError("unsupported operation schema_version")
    result = dict(operation)
    for field in ("operation_id", "operation_type", "target", "revision"):
        result[field] = _nonempty(operation.get(field), field)
    result["acceptance_criteria"] = _unique_strings(operation.get("acceptance_criteria"), "acceptance_criteria")
    if not result["acceptance_criteria"]:
        raise ContractError("acceptance_criteria must not be empty")
    policy = operation.get("policy", {})
    if not isinstance(policy, Mapping):
        raise ContractError("policy must be an object")
    result["policy"] = dict(policy)
    result["policy"]["required_evidence"] = _unique_strings(policy.get("required_evidence", []), "policy.required_evidence")
    return result

def validate_evidence(evidence: Any) -> list[dict[str, Any]]:
    if not isinstance(evidence, list):
        raise ContractError("evidence must be an array")
    normalized, seen = [], set()
    for index, item in enumerate(evidence):
        if not isinstance(item, Mapping):
            raise ContractError(f"evidence[{index}] must be an object")
        record = dict(item)
        for field in ("evidence_id", "kind", "source", "revision", "locator"):
            record[field] = _nonempty(item.get(field), f"evidence[{index}].{field}")
        if item.get("status") not in EVIDENCE_STATES:
            raise ContractError(f"evidence[{index}].status is unsupported")
        if record["evidence_id"] in seen:
            raise ContractError(f"duplicate evidence_id: {record['evidence_id']}")
        seen.add(record["evidence_id"])
        record["status"] = item["status"]
        normalized.append(record)
    return normalized

def _digest(payload: Mapping[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def evaluate_preflight(operation: Mapping[str, Any], evidence: Any, blockers: Any = None, warnings: Any = None) -> dict[str, Any]:
    """Evaluate readiness; never execute or authorize the requested operation."""
    op = validate_operation(operation)
    records = validate_evidence(evidence)
    blockers = _unique_strings(blockers or [], "blockers")
    warnings = _unique_strings(warnings or [], "warnings")
    kinds = {record["kind"] for record in records}
    required = set(op["policy"]["required_evidence"])
    missing = sorted(required - kinds)
    uncertain = [r["evidence_id"] for r in records if r["status"] in {"contradicted", "stale", "incomplete", "inaccessible", "unknown"}]
    blockers.extend(f"required evidence kind unavailable: {kind}" for kind in missing)
    if any(r["status"] == "contradicted" for r in records):
        blockers.append("contradictory evidence requires resolution")
    if blockers:
        status = "blocked"
    elif not records:
        status = "unavailable"
    elif missing or any(r["status"] in {"incomplete", "inaccessible", "unknown"} for r in records):
        status = "incomplete"
    elif uncertain or warnings:
        status = "ready_with_warnings"
    else:
        status = "ready"
    result = {
        "schema_version": SCHEMA_VERSION, "kind": "preflight_result",
        "operation_id": op["operation_id"], "operation_type": op["operation_type"],
        "target": op["target"], "revision": op["revision"], "status": status,
        "evidence": records,
        "coverage": {"required_kinds": sorted(required), "observed_kinds": sorted(kinds),
                     "missing_kinds": missing, "uncertain_evidence_ids": sorted(uncertain)},
        "blockers": sorted(set(blockers)), "warnings": sorted(set(warnings)),
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "authority": {"read_only": True, "operation_authorized": False, "mutation_performed": False},
    }
    result["result_digest"] = _digest(result)
    return result

def evaluate_postflight(operation: Mapping[str, Any], preflight: Mapping[str, Any], evidence: Any,
                        criteria_results: Mapping[str, Any], deviations: Any = None) -> dict[str, Any]:
    """Verify reported outcomes against acceptance criteria; never remediate."""
    op = validate_operation(operation)
    if not isinstance(preflight, Mapping) or preflight.get("operation_id") != op["operation_id"]:
        raise ContractError("preflight operation_id does not match operation")
    if preflight.get("revision") != op["revision"] or preflight.get("target") != op["target"]:
        raise ContractError("preflight target/revision does not match operation")
    records = validate_evidence(evidence)
    if not isinstance(criteria_results, Mapping):
        raise ContractError("criteria_results must be an object")
    allowed = {"passed", "failed", "skipped", "not_run", "inconclusive", "unverifiable"}
    normalized = {}
    for criterion in op["acceptance_criteria"]:
        value = criteria_results.get(criterion, "not_run")
        if value not in allowed:
            raise ContractError(f"unsupported result for acceptance criterion {criterion!r}")
        normalized[criterion] = value
    extras = sorted(set(criteria_results) - set(op["acceptance_criteria"]))
    deviations = _unique_strings(deviations or [], "deviations")
    values = set(normalized.values())
    if "failed" in values or deviations:
        status = "failed"
    elif "unverifiable" in values:
        status = "unverifiable"
    elif "inconclusive" in values:
        status = "inconclusive"
    elif "not_run" in values or "skipped" in values:
        status = "partial"
    elif values == {"passed"}:
        status = "passed"
    else:
        status = "inconclusive"
    result = {
        "schema_version": SCHEMA_VERSION, "kind": "postflight_result",
        "operation_id": op["operation_id"], "operation_type": op["operation_type"],
        "target": op["target"], "revision": op["revision"],
        "preflight_digest": preflight.get("result_digest"), "status": status,
        "acceptance_criteria": normalized, "unexpected_criteria": extras,
        "evidence": records, "deviations": deviations,
        "follow_up_required": status != "passed" or bool(extras),
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "authority": {"read_only": True, "remediation_authorized": False, "mutation_performed": False},
    }
    result["result_digest"] = _digest(result)
    return result
